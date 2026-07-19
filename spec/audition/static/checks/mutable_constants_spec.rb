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

  it "brackets bare multi-value constants when wrapping" do
    code = "ATTRS = :a, :b, :c\n"
    finding = findings_for(code).first

    fix = finding.autofix
    fixed = code.dup
    fixed[fix.start_offset...fix.end_offset] = fix.replacement
    expect(fixed).to eq(
      "ATTRS = Ractor.make_shareable([:a, :b, :c])\n"
    )
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

  it "stays silent on values it cannot classify statically" do
    findings = findings_for("SETTINGS = YAML.load_file('config.yml')\n")

    expect(findings).to be_empty
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
end
