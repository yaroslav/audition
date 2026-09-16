# frozen_string_literal: true

RSpec.describe Audition::Static::Checks::MutableConstants do
  def findings_for(code)
    analyzer =
      Audition::Static::Analyzer.new(checks: [described_class])
    analyzer.analyze_source(code, path: "test.rb")
  end

  it "flags constants holding bare mutable literals" do
    findings = findings_for(<<~RUBY)
      CACHE = {}
      LIST = [1, 2]
      NAME = "audition"
    RUBY

    expect(findings.map(&:line)).to eq([1, 2, 3])
    expect(findings).to all(have_attributes(severity: :error))
    expect(findings.first.why).to include("Ractor::IsolationError")
  end

  it "flags nested mutable elements under a top-level freeze as shallow" do
    findings = findings_for("MATRIX = [[1], [2]].freeze\n")

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("top level")
    expect(findings.first.fix).to include("make_shareable")
  end

  it "accepts deeply immutable frozen literals" do
    findings = findings_for(<<~RUBY)
      NUMS = [1, 2.5, :three, nil, true].freeze
      TABLE = { a: 1, b: :two }.freeze
    RUBY

    expect(findings).to be_empty
  end

  it "treats string literals as shareable under frozen_string_literal" do
    with_magic = findings_for(<<~RUBY)
      # frozen_string_literal: true
      NAME = "audition"
      WORDS = %w[a b].freeze
    RUBY
    without_magic = findings_for("WORDS = %w[a b].freeze\n")

    expect(with_magic).to be_empty
    expect(without_magic.size).to eq(1)
  end

  it "accepts adjacent string literals under frozen_string_literal" do
    findings = findings_for(<<~'RUBY')
      # frozen_string_literal: true
      USAGE = "usage: audition " \
              "[options] TARGET"
    RUBY

    expect(findings).to be_empty
  end

  it "brackets bare multi-value constants when freezing" do
    code = "ATTRS = :a, :b, :c\n"
    finding = findings_for(code).first

    fix = finding.autofix
    fixed = code.dup
    fixed[fix.start_offset...fix.end_offset] = fix.replacement
    expect(fixed).to eq("ATTRS = [:a, :b, :c].freeze\n")
    expect(fix.unsafe?).to be(false)
  end

  it "brackets bare multi-value constants when wrapping" do
    code = "ATTRS = :a, [:b]\n"
    finding = findings_for(code).first

    fix = finding.autofix
    fixed = code.dup
    fixed[fix.start_offset...fix.end_offset] = fix.replacement
    expect(fixed).to eq(
      "ATTRS = Ractor.make_shareable([:a, [:b]])\n"
    )
    expect(fix.unsafe?).to be(true)
  end

  it "recognizes top-level-qualified sync primitives" do
    findings = findings_for("LOCK = ::Mutex.new\n")

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("sync primitive")
  end

  it "refuses make_shareable for containers of sync primitives" do
    findings = findings_for(<<~RUBY)
      MUTEXES = { adapter: Mutex.new }.freeze
      LOCKS = [Mutex.new]
    RUBY

    expect(findings.size).to eq(2)
    expect(findings).to all(have_attributes(severity: :error))
    expect(findings.none?(&:fixable?)).to be(true)
    expect(findings.first.message).to include("sync primitive")
  end

  it "flags Hash.new with a default proc, even frozen" do
    findings = findings_for(<<~RUBY)
      TABLE = Hash.new { |h, k| h[k] = [] }
      EMPTY = Hash.new { "" }.freeze
    RUBY

    expect(findings.map(&:line)).to eq([1, 2])
    expect(findings).to all(have_attributes(severity: :error))
    expect(findings.first.message).to include("default proc")
    expect(findings.first.fix).to include("explicit")
  end

  it "classifies bare Hash.new and Array.new as mutable" do
    findings = findings_for(<<~RUBY)
      CACHE = Hash.new
      SLOTS = Array.new(3)
    RUBY

    expect(findings.size).to eq(2)
    expect(findings.first.message).to include("mutable")
  end

  it "treats index writes as mutation" do
    findings = findings_for(<<~RUBY)
      COUNTS = Hash.new(0)
      def self.bump(k) = COUNTS[k] += 1
      CACHE = {}
      def self.get(k) = CACHE[k] ||= compute(k)
    RUBY

    containers = findings.select { |f| f.message.include?("mutable") }
    expect(containers.size).to eq(2)
    expect(containers.none?(&:fixable?)).to be(true)
    mutations = findings.select do |f|
      f.message.include?("in-place")
    end
    expect(mutations.map(&:line)).to contain_exactly(2, 4)
  end

  it "handles Proc.new and proc call forms without crashing" do
    findings = findings_for(<<~RUBY)
      module Notify
        RAISE_NOTIFIER = Proc.new { |err| raise err }
        SILENT = proc {}
      end
    RUBY

    expect(findings.size).to eq(2)
    expect(findings).to all(
      have_attributes(check: "mutable-constants")
    )
  end

  it "handles procs built from a block argument" do
    findings = findings_for(<<~RUBY)
      module Matchers
        TRUE_NODE = lambda(&:true_type?)
        SHOUT = proc(&:upcase)
        WRAPPED = Proc.new(&handler)
      end
    RUBY

    expect(findings.size).to eq(3)
    expect(findings).to all(
      have_attributes(check: "mutable-constants")
    )
  end

  it "withholds proc wraps when the block comes from elsewhere" do
    findings = findings_for(<<~RUBY)
      module Matchers
        OPAQUE = lambda(&handler)
        CLEAN = lambda { |msg| msg.to_s }
      end
    RUBY

    by_name = findings.to_h { |f| [f.message[/[A-Z]+/], f] }
    expect(by_name["OPAQUE"].autofix).to be_nil
    expect(by_name["CLEAN"].autofix).not_to be_nil
  end

  it "gates proc wraps on capture-free lambdas in a namespace" do
    findings = findings_for(<<~RUBY)
      TOP = ->(x) { x.to_s }

      module Formats
        defaults = {}
        CAPTURING = -> { defaults }
        CLEAN = ->(msg) { msg.to_s }
      end
    RUBY

    by_name = findings.to_h { |f| [f.message[/[A-Z]+/], f] }
    expect(by_name["TOP"].autofix).to be_nil
    expect(by_name["CAPTURING"].autofix).to be_nil
    expect(by_name["CLEAN"].autofix).not_to be_nil
    expect(by_name["CLEAN"].autofix.unsafe?).to be(true)
  end

  it "marks make_shareable wraps as unsafe tier" do
    findings = findings_for("CACHE = { a: [] }\n")

    fix = findings.first.autofix
    expect(fix.unsafe?).to be(true)
  end

  it "withholds autofixes for constants the file mutates" do
    findings = findings_for(<<~RUBY)
      PARAMS = {}
      def self.record(v) = PARAMS[:k] = v
    RUBY

    container = findings.find { |f| f.message.include?("mutable") }
    expect(container.severity).to eq(:error)
    expect(container.fixable?).to be(false)
  end

  it "flags in-place mutation of screaming-case constants" do
    findings = findings_for(<<~RUBY)
      RENDERERS << :json
      LOOKUP["get"] = :get
      Config::DEFAULTS.merge!(a: 1)
    RUBY

    expect(findings.map(&:line)).to eq([1, 2, 3])
    expect(findings).to all(have_attributes(severity: :warning))
    expect(findings.first.message).to include("RENDERERS")
    expect(findings.first.fix).to include("freeze")
    expect(findings.first.fix).to include("Ractor.make_shareable")
    expect(findings.first.fix).to include("keyword")
  end

  it "names the keyword-default move for public mutable constants" do
    findings = findings_for("HTTP_METHODS = %w[GET POST]\n")

    expect(findings.first.fix).to include("keyword")
  end

  it "leaves mutator-named calls on class constants alone" do
    findings = findings_for(<<~RUBY)
      Registry.push(:item)
      User << record
      LOOKUP.fetch(:get)
    RUBY

    expect(findings).to be_empty
  end

  it "still flags interpolated strings under frozen_string_literal" do
    findings = findings_for(<<~'RUBY')
      # frozen_string_literal: true
      BANNER = "v#{Audition::VERSION}"
    RUBY

    expect(findings.size).to eq(1)
  end

  it "suppresses everything under shareable_constant_value" do
    findings = findings_for(<<~RUBY)
      # shareable_constant_value: literal
      CACHE = {}
      LIST = [[1]]
    RUBY

    expect(findings).to be_empty
  end

  it "flags synchronization primitives with a dedicated explanation" do
    findings = findings_for(<<~RUBY)
      LOCK = Mutex.new
      JOBS = Queue.new
    RUBY

    expect(findings.size).to eq(2)
    expect(findings.first.message).to include("Mutex")
    expect(findings.first.fix).to include("Ractor::Port")
  end

  it "flags Proc constants with an isolation-aware fix" do
    findings = findings_for("HANDLER = ->(x) { x * 2 }\n")

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("Proc")
    expect(findings.first.fix).to include("make_shareable")
  end

  it "accepts shareable values and known-shareable constructors" do
    findings = findings_for(<<~RUBY)
      MAX = 100
      PATTERN = /ab+c/
      RANGE = (1..10)
      Point = Struct.new(:x, :y)
      Config = Data.define(:host)
      SAFE = Ractor.make_shareable([1, [2]])
    RUBY

    expect(findings).to be_empty
  end

  it "warns on constants holding unprovable call results" do
    findings = findings_for("SETTINGS = YAML.load_file('config.yml')\n")

    expect(findings.size).to eq(1)
    finding = findings.first
    expect(finding.severity).to eq(:warning)
    expect(finding.message)
      .to include("SETTINGS", "a YAML.load_file call")
    expect(finding).not_to be_fixable
  end

  it "trusts calls that return shareable primitives" do
    findings = findings_for(<<~RUBY)
      TTL = 5.minutes.to_i
      WIDTH = Config.fetch(:width).to_f
      KEY = ENV.fetch("MODE").to_sym
      READY = Feature.enabled?
    RUBY

    expect(findings).to be_empty
  end

  it "sees through Sorbet inline casts" do
    findings = findings_for(<<~RUBY)
      # frozen_string_literal: true
      TYPED = T.let("x", String)
      LOOSE = T.let(compute, T.untyped)
      GOOD = T.must(42)
    RUBY

    expect(findings.map(&:line)).to eq([3])
    expect(findings.first.message).to include("LOOSE")
  end

  it "names the literal and fixes inside a Sorbet cast" do
    code = "# frozen_string_literal: true\n" \
      "MAP = T.let({a: 1}, T::Hash[Symbol, Integer])\n"
    findings = findings_for(code)

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("Hash")
    fix = findings.first.autofix
    expect(fix.unsafe?).to be(false)
    fixed = code.dup
    fixed[fix.start_offset...fix.end_offset] = fix.replacement
    expect(fixed).to include("T.let({a: 1}.freeze,")
  end

  it "flags writes through constant paths" do
    findings = findings_for("Foo::BAR = []\n")

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("Foo::BAR")
  end

  describe "autofixes" do
    it "appends .freeze to plain string literals" do
      finding = findings_for('NAME = "audition"').first

      expect(finding).to be_fixable
      code = 'NAME = "audition"'
      fixed = code[0...finding.autofix.start_offset] +
        finding.autofix.replacement +
        code[finding.autofix.end_offset..]
      expect(fixed).to eq('NAME = "audition".freeze')
    end

    it "wraps mutable containers in Ractor.make_shareable" do
      code = "CACHE = { a: [1] }"
      finding = findings_for(code).first

      fixed = code[0...finding.autofix.start_offset] +
        finding.autofix.replacement +
        code[finding.autofix.end_offset..]
      expect(fixed).to eq("CACHE = Ractor.make_shareable({ a: [1] })")
    end

    it "replaces a shallow .freeze with a deep make_shareable" do
      code = "MATRIX = [[1], [2]].freeze"
      finding = findings_for(code).first

      fixed = code[0...finding.autofix.start_offset] +
        finding.autofix.replacement +
        code[finding.autofix.end_offset..]
      expect(fixed).to eq("MATRIX = Ractor.make_shareable([[1], [2]])")
    end

    it "offers no autofix for sync primitives" do
      expect(findings_for("LOCK = Mutex.new").first).not_to be_fixable
    end
  end

  it "flags constants built from calls that return fresh strings" do
    findings = findings_for(<<~RUBY)
      # frozen_string_literal: true
      WITH_COLON = "+00:00"
      WITHOUT_COLON = WITH_COLON.tr(":", "")
      UPPER = "abc".upcase
      JOINED = "a" + "b"
      LABEL = format("%d items", 3)
      RAW = String.new("x")
    RUBY

    expect(findings.map(&:line)).to eq([3, 4, 5, 6, 7])
    expect(findings).to all(have_attributes(severity: :error))
    expect(findings).to all(be_fixable)
    expect(findings.first.message).to include("String")
    expect(findings.first.fix).to include(".freeze")
    expect(findings.first.why).to include("frozen_string_literal")
  end

  it "flags constants holding Regexps built at load time" do
    findings = findings_for(<<~RUBY)
      TAG = Regexp.new("x")
      ANY = Regexp.union("a", "b")
      SAFE = Regexp.new("x").freeze
      LITERAL = /x/
    RUBY

    expect(findings.map(&:line)).to eq([1, 2])
    expect(findings.first.message).to include("Regexp")
    expect(findings.first.message).to include("Regexp.new")
  end

  it "accepts frozen call results" do
    findings = findings_for(<<~RUBY)
      # frozen_string_literal: true
      A = "+00:00".tr(":", "").freeze
      B = format("%d", 1).freeze
      C = Regexp.union("a", "b").freeze
    RUBY

    expect(findings).to be_empty
  end

  it "warns on ambiguous calls on non-literal receivers" do
    findings = findings_for(<<~RUBY)
      # frozen_string_literal: true
      SUM = Totals.sum + 1
      NAME = Label.upcase
      PATH = Settings.dup
    RUBY

    expect(findings.map(&:line)).to eq([2, 3, 4])
    expect(findings).to all(have_attributes(severity: :warning))
    expect(findings).to all(satisfy { |f| !f.fixable? })
  end

  it "stays quiet once the opaque result is frozen later" do
    findings = findings_for(<<~RUBY)
      SETTINGS = YAML.load_file("config.yml")
      SETTINGS.freeze
    RUBY

    expect(findings).to be_empty
  end

  it "warns when a freeze covers only the surface of opaque values" do
    findings = findings_for(<<~RUBY)
      # frozen_string_literal: true
      COUNTERS = T.let({cache: Stats.build("c")}.freeze, T.untyped)
      FORMATS = [Mime[:xml], Mime[:json]].freeze
      EPOCH = T.let(Time.at(0).freeze, Time)
      CODEC = Encoder.new(0, MAP).freeze
      CLASSES = [Widget, Gadget].freeze
    RUBY

    expect(findings.map(&:line)).to eq([2, 3, 4, 5])
    expect(findings).to all(have_attributes(severity: :warning))
    expect(findings).to all(satisfy { |f| !f.fixable? })
    expect(findings.first.message).to include("frozen at the top")
  end

  it "does not let constant-read keys excuse opaque values" do
    findings = findings_for(<<~RUBY)
      CONFIGS = {
        Sizes::SMALL => Widget.new(a: 1),
      }.freeze
    RUBY

    expect(findings.size).to eq(1)
    expect(findings.first.severity).to eq(:warning)
    expect(findings.first.message).to include("frozen at the top")
  end

  it "reports a provably mutable element despite unknown siblings" do
    findings = findings_for(<<~RUBY)
      REGISTRY = [Widget, [1]].freeze
    RUBY

    expect(findings.size).to eq(1)
    expect(findings.first.severity).to eq(:error)
    expect(findings.first.message).to include("frozen only")
  end

  it "warns when a container of opaque values is frozen later" do
    findings = findings_for(<<~RUBY)
      ROUTES = {home: Router.build}
      ROUTES.freeze
    RUBY

    expect(findings.size).to eq(1)
    expect(findings.first.severity).to eq(:warning)
    expect(findings.first.message).to include("frozen at the top")
  end

  it "trusts indexing into ENV and Sorbet type constructors" do
    findings = findings_for(<<~RUBY)
      HOME = ENV["HOME"]
      LIST = T::Array[String]
      XML = Mime[:xml]
    RUBY

    expect(findings.map(&:line)).to eq([3])
    expect(findings.first.severity).to eq(:warning)
    expect(findings.first.message).to include("Mime.[]")
  end

  it "flags indexing into another call's result" do
    findings = findings_for(<<~RUBY)
      KEY = Registry.by_name["WIDTH"]
    RUBY

    expect(findings.map(&:line)).to eq([1])
    expect(findings.first.severity).to eq(:warning)
  end

  it "treats frozen File path results as shareable" do
    findings = findings_for(<<~RUBY)
      ROOT = File.expand_path("..", __dir__).freeze
      BARE = File.join("a", "b")
    RUBY

    expect(findings.map(&:line)).to eq([2])
    expect(findings.first.severity).to eq(:error)
    expect(findings.first.message).to include("File.join")
  end
  describe "plain freeze for provably shareable containers" do
    it "appends .freeze when every element is shareable" do
      code = "# frozen_string_literal: true\nLIST = [1, \"a\", :b]\n"
      finding = findings_for(code).first

      fix = finding.autofix
      expect(fix.unsafe?).to be(false)
      fixed = code.dup
      fixed[fix.start_offset...fix.end_offset] = fix.replacement
      expect(fixed).to end_with("LIST = [1, \"a\", :b].freeze\n")
      expect(finding.fix).to include(".freeze")
    end

    it "freezes an empty hash bare" do
      code = "CACHE = {}\n"
      fix = findings_for(code).first.autofix

      fixed = code.dup
      fixed[fix.start_offset...fix.end_offset] = fix.replacement
      expect(fixed).to eq("CACHE = {}.freeze\n")
    end

    it "keeps the deep wrap for unfrozen string elements" do
      fix = findings_for("NAMES = [\"a\"]\n").first.autofix

      expect(fix.replacement).to start_with("Ractor.make_shareable")
      expect(fix.unsafe?).to be(true)
    end
  end

  describe "sentinel objects" do
    it "flags bare Object.new sentinels with a .freeze fix" do
      code = "NOT_GIVEN = Object.new\n"
      findings = findings_for(code)

      expect(findings.size).to eq(1)
      finding = findings.first
      expect(finding.severity).to eq(:error)
      expect(finding.message).to include("Object")
      expect(finding.message).to include("Object.new")
      fix = finding.autofix
      expect(fix.unsafe?).to be(false)
      fixed = code.dup
      fixed[fix.start_offset...fix.end_offset] = fix.replacement
      expect(fixed).to eq("NOT_GIVEN = Object.new.freeze\n")
    end

    it "accepts frozen sentinels" do
      findings = findings_for(<<~RUBY)
        DEFAULT = Object.new.freeze
        POISON = ::Object.new.freeze
      RUBY

      expect(findings).to be_empty
    end

    it "replaces BasicObject sentinels, which cannot be frozen" do
      code = "NOT_SET = BasicObject.new\n"
      finding = findings_for(code).first

      expect(finding.fix).to include("BasicObject")
      fix = finding.autofix
      expect(fix.unsafe?).to be(true)
      fixed = code.dup
      fixed[fix.start_offset...fix.end_offset] = fix.replacement
      expect(fixed).to eq("NOT_SET = Object.new.freeze\n")
    end

    it "withholds the fix from sentinels the file customizes" do
      findings = findings_for(<<~RUBY)
        NULL = Object.new
        def NULL.to_s = "null"
        EXTENDED = Object.new
        EXTENDED.extend(Comparable)
        PLAIN = Object.new
      RUBY

      by_name = findings.to_h { |f| [f.message[/constant (\S+)/, 1], f] }
      expect(by_name.keys)
        .to contain_exactly("NULL", "EXTENDED", "PLAIN")
      expect(by_name["NULL"].fixable?).to be(false)
      expect(by_name["EXTENDED"].fixable?).to be(false)
      expect(by_name["PLAIN"].fixable?).to be(true)
    end

    it "leaves Object.new with arguments or a block alone" do
      findings = findings_for("WITH_BLOCK = Object.new { }\n")

      expect(findings).to be_empty
    end

    it "warns on fresh instances of arbitrary classes" do
      findings = findings_for(<<~RUBY)
        SOMETHING = Widget.new
        FROZEN = Widget.new.freeze
        QUERY = Db::Query.new(name: "q") { |x| x }
      RUBY

      expect(findings.map(&:line)).to eq([1, 2, 3])
      expect(findings).to all(have_attributes(severity: :warning))
      expect(findings.first.message)
        .to include("SOMETHING", "Widget")
      expect(findings[1].message).to include("frozen at the top")
    end
  end

  describe "Set constants" do
    it "flags Set factories as mutable containers" do
      findings = findings_for(<<~RUBY)
        # frozen_string_literal: true
        IDS = %w(id id= id?).to_set
        DIRS = Set.new([:asc, :desc])
        KEYS = Set[1, 2]
        EMPTY = Set.new
      RUBY

      expect(findings.map(&:line)).to eq([2, 3, 4, 5])
      expect(findings).to all(have_attributes(severity: :error))
      expect(findings.map(&:message)).to all(include("Set"))
      expect(findings).to all(be_fixable)
      expect(findings.map { |f| f.autofix.replacement })
        .to all(eq(".freeze"))
    end

    it "treats a frozen Set of mutable elements as shallow" do
      findings = findings_for(<<~RUBY)
        STRS = Set.new(["a"]).freeze
        NESTED = Set[[1]]
      RUBY

      expect(findings.map(&:line)).to eq([1, 2])
      expect(findings.first.message).to include("frozen only")
      expect(findings.last.autofix.replacement)
        .to start_with("Ractor.make_shareable")
    end

    it "accepts frozen Sets of shareable elements and unknown sources" do
      findings = findings_for(<<~RUBY)
        # frozen_string_literal: true
        IDS = %w(id id=).to_set.freeze
        DIRS = Set.new([:asc]).freeze
        SEALED = Set.new(compute).freeze
      RUBY

      expect(findings).to be_empty
    end

    it "flags unfrozen Sets built from opaque sources" do
      findings = findings_for(<<~RUBY)
        DYNAMIC = Set.new(compute)
        MAPPED = Set.new([1]) { |x| x.to_s }
      RUBY

      expect(findings.map(&:line)).to eq([1, 2])
      expect(findings).to all(have_attributes(severity: :error))
      expect(findings.map(&:message)).to all(include("Set"))
    end
  end

  describe "constants frozen later in the same body" do
    it "accepts a build-then-freeze at the same lexical level" do
      findings = findings_for(<<~RUBY)
        # frozen_string_literal: true
        module XmlMini
          TYPE_NAMES = { "Symbol" => "symbol" }
          TYPE_NAMES["TimeWithZone"] = TYPE_NAMES["Time"]
          TYPE_NAMES.freeze
        end
      RUBY

      expect(findings.map(&:message)).to all(include("in-place"))
      expect(findings.map(&:line)).to eq([4])
    end

    it "still reports mutable elements under a later freeze" do
      findings = findings_for(<<~RUBY)
        NESTED = { a: [1] }
        NESTED.freeze
      RUBY

      expect(findings.size).to eq(1)
      expect(findings.first.message).to include("frozen only")
      expect(findings.first.fixable?).to be(false)
    end

    it "ignores freezes that live inside a method" do
      findings = findings_for(<<~RUBY)
        REGISTRY = {}
        def self.finalize! = REGISTRY.freeze
      RUBY

      expect(findings.map(&:message))
        .to include(a_string_including("mutable Hash"))
    end

    it "keeps flagging a default proc despite a later freeze" do
      findings = findings_for(<<~RUBY)
        PRE = Hash.new { "" }
        PRE.freeze
      RUBY

      expect(findings.first.message).to include("default proc")
    end
  end

  describe "begin blocks" do
    it "classifies a constant by the block's last statement" do
      findings = findings_for(<<~RUBY)
        TABLE = begin
          {a: {b: 1}}
        end.freeze
      RUBY

      expect(findings.size).to eq(1)
      expect(findings.first.message).to include("top level")
    end

    it "accepts a block whose last statement is shareable" do
      findings = findings_for(<<~RUBY)
        LIST = begin
          [1, 2]
        end.freeze
      RUBY

      expect(findings).to be_empty
    end

    it "leaves a block with a rescue clause alone" do
      findings = findings_for(<<~RUBY)
        TABLE = begin
          {a: {b: 1}}
        rescue StandardError
          {}
        end.freeze
      RUBY

      expect(findings).to be_empty
    end
  end

  describe "strings built by joining an array literal" do
    it "flags the joined version string as a fixable error" do
      code = <<~RUBY
        # frozen_string_literal: true
        VERSION = [8, 2, 0].join(".")
      RUBY
      findings = findings_for(code)

      expect(findings.size).to eq(1)
      finding = findings.first
      expect(finding.severity).to eq(:error)
      expect(finding.message).to include("Array#join")
      fix = finding.autofix
      expect(fix.unsafe?).to be(false)
      fixed = code.dup
      fixed[fix.start_offset...fix.end_offset] = fix.replacement
      expect(fixed).to end_with('VERSION = [8, 2, 0].join(".").freeze' + "\n")
    end

    it "follows a chain of array methods back to the literal" do
      findings = findings_for(<<~RUBY)
        STRING = [MAJOR, MINOR, TINY, PRE].compact.join(".")
        WORDS = %w[a b].map(&:upcase).join("-")
      RUBY

      expect(findings.map(&:line)).to eq([1, 2])
      expect(findings).to all(have_attributes(severity: :error))
      expect(findings.map(&:fixable?)).to all(be(true))
    end

    it "keeps join on an unknown receiver a warning" do
      findings = findings_for(<<~RUBY)
        PARTS = SEGMENTS.join(".")
      RUBY

      expect(findings.size).to eq(1)
      expect(findings.first.severity).to eq(:warning)
    end

    it "accepts the joined string once frozen" do
      findings = findings_for(<<~RUBY)
        VERSION = [8, 2, 0].join(".").freeze
      RUBY

      expect(findings).to be_empty
    end
  end

  describe "strings made from symbol literals" do
    it "flags Symbol#to_s as a fixable error" do
      code = "NAME = :audition.to_s\n"
      findings = findings_for(code)

      expect(findings.size).to eq(1)
      finding = findings.first
      expect(finding.severity).to eq(:error)
      expect(finding.message).to include("Symbol#to_s")
      fix = finding.autofix
      expect(fix.unsafe?).to be(false)
      fixed = code.dup
      fixed[fix.start_offset...fix.end_offset] = fix.replacement
      expect(fixed).to eq("NAME = :audition.to_s.freeze\n")
    end

    it "treats Symbol#name as shareable" do
      findings = findings_for("NAME = :audition.name\n")

      expect(findings).to be_empty
    end
  end

  describe "unary string operators" do
    it "flags a unary plus string and freezes it in parentheses" do
      code = <<~RUBY
        # frozen_string_literal: true
        BUFFER = +"draft"
      RUBY
      findings = findings_for(code)

      expect(findings.size).to eq(1)
      expect(findings.first.severity).to eq(:error)
      fix = findings.first.autofix
      fixed = code.dup
      fixed[fix.start_offset...fix.end_offset] = fix.replacement
      expect(fixed).to end_with('BUFFER = (+"draft").freeze' + "\n")
    end

    it "treats a unary minus string as shareable" do
      findings = findings_for(<<~RUBY)
        KEY = -"draft"
      RUBY

      expect(findings).to be_empty
    end
  end

  it "flags Concurrent::Map constants as never shareable" do
    findings = findings_for("CACHE = Concurrent::Map.new\n")

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("Concurrent::Map")
    expect(findings.first.fixable?).to be(false)
    expect(findings.first.fix).to include("store_if_absent")
  end
end
