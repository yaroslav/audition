# frozen_string_literal: true

RSpec.describe Audition::Static::GraphAudit do
  def findings_for(sources)
    described_class.new.analyze_sources(sources)
  end

  it "flags class variables at every definition site" do
    findings = findings_for(
      "a.rb" => <<~RUBY
        class Legacy
          @@count = 0
          def bump = (@@count += 1)
        end
      RUBY
    )

    cvars = findings.select { |f| f.check == "class-variables" }
    expect(cvars.map(&:line)).to contain_exactly(2, 3)
    expect(cvars).to all(have_attributes(severity: :error))
    expect(cvars.first.message).to include("@@count")
    expect(cvars.first.message).to include("Legacy")
    expect(cvars.first.why).to include("non-main Ractors")
  end

  it "unifies class-level ivars across contexts and files" do
    findings = findings_for(
      "a.rb" => <<~RUBY,
        class Widget
          @registry = {}
          def self.reset! = (@registry = {})
          def tag = (@label = 1)
        end
      RUBY
      "b.rb" => <<~RUBY
        class Widget
          class << self
            def prime = (@registry ||= {})
          end
        end
      RUBY
    )

    state = findings.select { |f| f.check == "class-level-state" }
    expect(state.map { |f| [f.path, f.line] }).to contain_exactly(
      ["a.rb", 2], ["a.rb", 3], ["b.rb", 3]
    )
    expect(state).to all(have_attributes(severity: :error))
    expect(state.first.message).to include("@registry")
    expect(state.first.message).to include("Widget")
    expect(state.first.fix).to include("store_if_absent")
  end

  it "downgrades frozen memoization to an info note" do
    findings = findings_for(
      "platform.rb" => <<~RUBY
        module Platform
          class << self
            def windows?
              return @windows if defined?(@windows)

              @windows = RUBY_PLATFORM.match?(/mswin/).freeze
            end
          end
        end
      RUBY
    )

    expect(findings.size).to eq(1)
    note = findings.first
    expect(note.severity).to eq(:info)
    expect(note.message).to include("frozen memoization")
    expect(note.fix).to include("boot")
  end

  it "downgrades best-effort frozen setters to a warning" do
    findings = findings_for(
      "config.rb" => <<~RUBY
        module Config
          def self.backend = @backend

          def self.backend=(value)
            @backend = (Ractor.make_shareable(value) rescue value)
          end
        end
      RUBY
    )

    expect(findings.size).to eq(1)
    note = findings.first
    expect(note.severity).to eq(:warning)
    expect(note.message).to include("best-effort")
  end

  it "keeps shallow-frozen container memoization an error" do
    findings = findings_for(
      "registry.rb" => <<~RUBY
        module Registry
          def self.handlers
            @handlers ||= [Handler.new].freeze
          end
        end
      RUBY
    )

    expect(findings.first.severity).to eq(:error)
  end

  it "marks groups dirty when a singleton reopening writes" do
    findings = findings_for(
      "a.rb" => <<~RUBY,
        class Foo
          def self.config
            @config ||= "x".freeze
          end
        end
      RUBY
      "b.rb" => <<~RUBY
        class << Foo
          def bust!
            @config = load_yaml
          end
        end
      RUBY
    )

    expect(findings).to all(have_attributes(severity: :error))
  end

  it "keeps unfrozen memoization an error" do
    findings = findings_for(
      "cache.rb" => <<~RUBY
        module Cache
          def self.store
            return @store if defined?(@store)

            @store = {}
          end
        end
      RUBY
    )

    expect(findings.size).to eq(1)
    expect(findings.first.severity).to eq(:error)
  end

  it "keeps frozen memoization an error when a reset write exists" do
    findings = findings_for(
      "resettable.rb" => <<~RUBY
        module Registry
          def self.all
            return @all if defined?(@all)

            @all = compute.freeze
          end

          def self.reset! = (@all = nil)
        end
      RUBY
    )

    expect(findings).to all(have_attributes(severity: :error))
  end

  it "does not flag instance-level ivars" do
    findings = findings_for(
      "a.rb" => "class A\n  def x = (@ok = 1)\nend\n"
    )

    expect(findings).to be_empty
  end

  it "flags module-level ivars" do
    findings = findings_for(
      "m.rb" => "module Settings\n  @config = {}\nend\n"
    )

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("@config")
    expect(findings.first.message).to include("Settings")
  end

  describe "singleton attributes" do
    it "flags a writable attribute on a singleton class" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Vault
            class << self
              attr_accessor :current
            end
          end
        RUBY
      )

      expect(findings.size).to eq(1)
      expect(findings.first).to have_attributes(
        check: "class-level-state", line: 3, severity: :error
      )
      expect(findings.first.message).to include("@current")
      expect(findings.first.message).to include("Vault")
    end

    it "names the class a reopened singleton belongs to" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class << Vault
            attr_writer :store, "backup"
          end
        RUBY
      )

      expect(findings.map(&:message)).to contain_exactly(
        a_string_including("@store on Vault"),
        a_string_including("@backup on Vault")
      )
    end

    it "leaves a lone reader to the graph" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Vault
            class << self
              attr_reader :current
            end
          end
        RUBY
      )

      expect(findings).to be_empty
    end

    it "ignores an attribute on the instance side" do
      findings = findings_for(
        "a.rb" => "class Vault\n  attr_accessor :name\nend\n"
      )

      expect(findings).to be_empty
    end

    it "ignores an attribute call nested inside a def" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Vault
            class << self
              def install = attr_accessor(:current)
            end
          end
        RUBY
      )

      expect(findings).to be_empty
    end

    it "flags an assignment to a declared attribute" do
      findings = findings_for(
        "a.rb" => <<~RUBY,
          class Vault
            class << self
              attr_accessor :current
            end
          end
        RUBY
        "b.rb" => "Vault.current = Vault.new\n"
      )

      expect(findings.map { |f| [f.path, f.line] })
        .to contain_exactly(["a.rb", 3], ["b.rb", 1])
      expect(findings.last.message).to include("@current on Vault")
    end

    it "matches a write spelled through a longer path" do
      findings = findings_for(
        "a.rb" => <<~RUBY,
          module Kit
            class Vault
              class << self
                attr_writer :store
              end
            end
          end
        RUBY
        "b.rb" => "Kit::Vault.store = {}\n"
      )

      expect(findings.map(&:path)).to contain_exactly("a.rb", "b.rb")
    end

    it "leaves a read of a declared attribute alone" do
      findings = findings_for(
        "a.rb" => <<~RUBY,
          class Vault
            class << self
              attr_accessor :current
            end
          end
        RUBY
        "b.rb" => "Vault.current\n"
      )

      expect(findings.map(&:path)).to contain_exactly("a.rb")
    end

    it "leaves a writer nothing declares alone" do
      findings = findings_for(
        "a.rb" => "Vault.current = 1\n"
      )

      expect(findings).to be_empty
    end
  end

  describe "extended modules" do
    it "flags an ivar written in a module something extends" do
      findings = findings_for(
        "a.rb" => <<~RUBY,
          module Scoped
            def scope(name)
              @scope = name
            end
          end
        RUBY
        "b.rb" => "class Vault\n  extend Scoped\nend\n"
      )

      expect(findings.size).to eq(1)
      expect(findings.first).to have_attributes(
        path: "a.rb", line: 3, severity: :error
      )
      expect(findings.first.message).to include("@scope on Scoped")
    end

    it "matches an extend written through a longer path" do
      findings = findings_for(
        "a.rb" => <<~RUBY,
          module Kit
            module Scoped
              def scope(name) = (@scope = name)
            end
          end
        RUBY
        "b.rb" => "class Vault\n  extend Kit::Scoped\nend\n"
      )

      expect(findings.map(&:message)).to contain_exactly(
        a_string_including("@scope on Kit::Scoped")
      )
    end

    it "leaves a module nothing extends alone" do
      findings = findings_for(
        "a.rb" => <<~RUBY,
          module Plain
            def plain(name)
              @plain = name
            end
          end
        RUBY
        "b.rb" => "class Vault\n  include Plain\nend\n"
      )

      expect(findings).to be_empty
    end

    it "starts a nested class on its own instance side" do
      findings = findings_for(
        "a.rb" => <<~RUBY,
          module Scoped
            class Row
              def scope(name) = (@scope = name)
            end
          end
        RUBY
        "b.rb" => "class Vault\n  extend Scoped\nend\n"
      )

      expect(findings).to be_empty
    end
  end

  describe "dynamic instance variable writes" do
    it "flags a write through a class hook's argument" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Widget
            def self.inherited(subclass)
              subclass.instance_variable_set(:@name, @name)
            end
          end
        RUBY
      )

      expect(findings.size).to eq(1)
      expect(findings.first).to have_attributes(
        path: "a.rb", line: 3, severity: :error
      )
      expect(findings.first.message).to include("@name on subclass")
    end

    it "flags a removal on implicit self in a singleton" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Widget
            def self.reset
              remove_instance_variable(:@cache)
            end
          end
        RUBY
      )

      expect(findings.map(&:message)).to contain_exactly(
        a_string_including("@cache on Widget")
      )
    end

    it "flags a write on a constant the target declares" do
      findings = findings_for(
        "a.rb" => "class Vault\nend\n",
        "b.rb" => "Vault.instance_variable_set(:@store, {})\n"
      )

      expect(findings.map(&:path)).to contain_exactly("b.rb")
    end

    it "leaves a constant the target never declares alone" do
      findings = findings_for(
        "a.rb" => "Absent::Thing.instance_variable_set(:@x, 1)\n"
      )

      expect(findings).to be_empty
    end

    it "leaves a receiver it cannot prove is a class alone" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Widget
            def self.touch(other)
              other.instance_variable_set(:@x, 1)
            end
          end
        RUBY
      )

      expect(findings).to be_empty
    end

    it "reads a receiver's own class as a class" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Widget
            def self.touch(other)
              other.class.instance_variable_set(:@x, 1)
            end
          end
        RUBY
      )

      expect(findings.map(&:line)).to contain_exactly(3)
    end

    it "leaves the instance side alone" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Widget
            def touch
              instance_variable_set(:@x, 1)
            end
          end
        RUBY
      )

      expect(findings).to be_empty
    end

    it "leaves a name built at runtime alone" do
      findings = findings_for(
        "a.rb" => <<~RUBY
          class Widget
            def self.touch(key)
              instance_variable_set("@\#{key}", 1)
            end
          end
        RUBY
      )

      expect(findings).to be_empty
    end
  end

  describe "derived constants" do
    def seed(path, line, severity: :error,
      check: "mutable-constants")
      Audition::Finding.new(
        check: check,
        severity: severity,
        message: "constant seed",
        why: "w",
        fix: "f",
        path: path,
        line: line
      )
    end

    def derived_for(sources, seeds)
      described_class.new
        .analyze_sources(sources, constant_findings: seeds)
        .select { |f| f.check == "derived-constants" }
    end

    it "flags an alias of a flagged constant" do
      findings = derived_for(
        {"a.rb" => "PRIMARY = Object.new\nDEFAULT = PRIMARY\n"},
        [seed("a.rb", 1)]
      )

      expect(findings.size).to eq(1)
      expect(findings.first).to have_attributes(
        path: "a.rb", line: 2, severity: :error
      )
      expect(findings.first.message).to include("DEFAULT")
      expect(findings.first.message).to include("PRIMARY")
    end

    it "flags a frozen container holding a flagged constant" do
      findings = derived_for(
        {"a.rb" => <<~RUBY},
          module Registry
            WIDGET = Object.new
            ALL = [WIDGET].freeze
          end
        RUBY
        [seed("a.rb", 2)]
      )

      expect(findings.map(&:line)).to contain_exactly(3)
      expect(findings.first.message).to include("ALL")
    end

    it "propagates through chains and across files" do
      findings = derived_for(
        {
          "a.rb" => "module Config\n  BASE = Object.new\nend\n",
          "b.rb" => <<~RUBY
            module Config
              DEFAULT = BASE
              FALLBACK = DEFAULT
            end
          RUBY
        },
        [seed("a.rb", 2)]
      )

      expect(findings.map { |f| [f.path, f.line] })
        .to contain_exactly(["b.rb", 2], ["b.rb", 3])
    end

    it "propagates a declaration rubydex could not settle" do
      findings = derived_for(
        {
          "a.rb" => <<~RUBY,
            module Kit
              module Ops
                Fn = T.let(->(v) { v }, Proc)
              end
            end
          RUBY
          "b.rb" => <<~RUBY,
            class KitTest
              Short = Kit::Ops::Fn
              def go
                Short.call(1)
              end
            end
          RUBY
          "c.rb" => <<~RUBY
            module Shared
              def self.build(data, v)
                {x: data.fetch(:x, Kit::Ops::Fn.call(v))}
              end
            end
          RUBY
        },
        [seed("a.rb", 3)]
      )

      expect(findings.map { |f| [f.path, f.line] })
        .to include(["b.rb", 2])
    end

    it "attributes a reference inside a multi-line assignment " \
       "to the assignment line" do
      findings = derived_for(
        {"a.rb" => <<~RUBY},
          GADGET = Object.new
          TABLE = {
            default: GADGET
          }.freeze
        RUBY
        [seed("a.rb", 1)]
      )

      expect(findings.map(&:line)).to contain_exactly(2)
    end

    it "names a constant assigned an expression another check " \
       "flagged" do
      findings = derived_for(
        {"a.rb" => "TOKEN = Vault::API_TOKEN\n"},
        [seed("a.rb", 1, severity: :warning,
          check: "unshareable-reads")]
      )

      expect(findings.size).to eq(1)
      expect(findings.first).to have_attributes(
        line: 1, severity: :warning
      )
      expect(findings.first.message).to include("constant TOKEN")
    end

    it "attributes a contained seed to the assignment line and " \
       "follows the new name" do
      findings = derived_for(
        {"a.rb" => <<~RUBY},
          WIDGET = Kit.build(
            Vault::API_TOKEN
          )
          COPY = WIDGET
        RUBY
        [seed("a.rb", 2, check: "native-gem-calls")]
      )

      expect(findings.map(&:line)).to contain_exactly(1, 4)
      expect(findings.first.message).to include("WIDGET")
    end

    it "defers to a constant finding already at the line" do
      findings = derived_for(
        {"a.rb" => "TOKEN = Vault::API_TOKEN\n"},
        [seed("a.rb", 1),
          seed("a.rb", 1, check: "unshareable-reads")]
      )

      expect(findings).to be_empty
    end

    it "leaves expression findings outside assignments alone" do
      findings = derived_for(
        {"a.rb" => "def use = Vault::API_TOKEN\n"},
        [seed("a.rb", 1, check: "unshareable-reads")]
      )

      expect(findings).to be_empty
    end

    it "skips sites the per-file pass already flagged" do
      findings = derived_for(
        {"a.rb" => "PRIMARY = Object.new\nCOPY = PRIMARY\n"},
        [seed("a.rb", 1), seed("a.rb", 2)]
      )

      expect(findings).to be_empty
    end

    it "emits one finding per site and follows the seed severity" do
      findings = derived_for(
        {"a.rb" => <<~RUBY},
          FIRST = Object.new
          SECOND = Object.new
          BOTH = [FIRST, SECOND].freeze
        RUBY
        [seed("a.rb", 1, severity: :warning),
          seed("a.rb", 2, severity: :warning)]
      )

      expect(findings.size).to eq(1)
      expect(findings.first).to have_attributes(
        line: 3, severity: :warning
      )
    end

    it "leaves reads outside constant assignments alone" do
      findings = derived_for(
        {"a.rb" => "GADGET = Object.new\ndef use = GADGET\n"},
        [seed("a.rb", 1)]
      )

      expect(findings).to be_empty
    end

    it "ignores findings from other checks" do
      other = Audition::Finding.new(
        check: "class-variables",
        severity: :error,
        message: "class variable @@x on A",
        why: "w",
        fix: "f",
        path: "a.rb",
        line: 1
      )
      findings = derived_for(
        {"a.rb" => "PRIMARY = Object.new\nDEFAULT = PRIMARY\n"},
        [other]
      )

      expect(findings).to be_empty
    end
  end

  # The parallel path falls back to serial on any Ractor error, so
  # only an explicit check keeps the walks—and everything they
  # cross a Ractor boundary with—Ractor-safe.
  describe "parallel walks" do
    def wide_sources(count)
      count.times.to_h do |i|
        ["f#{i}.rb", <<~RUBY]
          class Wide#{i}
            @registry = {}
            class << self
              attr_accessor :cache
            end
            def self.prime = (@seen ||= [])
          end
          Wide#{i}.cache = {}
        RUBY
      end
    end

    it "reports what the serial walks report" do
      sources = wide_sources(
        Audition::Static::GraphAudit::PARALLEL_THRESHOLD + 4
      )

      serial = described_class.new
        .analyze_sources(sources, workers: 1)
      parallel = described_class.new
        .analyze_sources(sources, workers: 4)

      expect(parallel.size).to be > sources.size
      expect(parallel.map(&:location)).to eq(serial.map(&:location))
      expect(parallel.map(&:message)).to eq(serial.map(&:message))
    end

    it "runs the walks in Ractors rather than falling back" do
      audit = described_class.new
      expect(audit).not_to receive(:serial_batches)

      findings = audit.analyze_sources(
        wide_sources(
          Audition::Static::GraphAudit::PARALLEL_THRESHOLD + 4
        ),
        workers: 4
      )

      expect(findings).not_to be_empty
    end
  end

  describe "static scan" do
    def scans_for(sources)
      findings_for(sources).select { |f| f.check == "static-scan" }
    end

    # Silence is the claim under test as much as the findings are:
    # rubydex reports far more than matters here, and a check that
    # fired on all of it would be unreadable.
    it "flags class-level state behind a runtime receiver" do
      scans = scans_for(
        "a.rb" => <<~RUBY
          target = Registry.lookup(:thing)
          class << target
            @cache = {}
          end
        RUBY
      )

      expect(scans.map(&:line)).to contain_exactly(2)
      expect(scans.first).to have_attributes(severity: :warning)
      expect(scans.first.message).to include("singleton receiver")
      expect(scans.first.why).to include("Ractor::IsolationError")
    end

    it "flags a def on a runtime receiver that writes state" do
      scans = scans_for(
        "a.rb" => <<~RUBY
          obj = build
          def obj.tweak = (@state = 1)
        RUBY
      )

      expect(scans.map(&:line)).to contain_exactly(2)
    end

    it "ignores a runtime singleton that writes no state" do
      expect(
        scans_for(
          "a.rb" => <<~RUBY
            target = Registry.lookup(:thing)
            class << target
              def pure(x) = x + 1
            end
          RUBY
        )
      ).to be_empty
    end

    # A nested class owns its own state and the graph resolves it,
    # so the unresolved receiver hides nothing.
    it "ignores state a class nested in the singleton declares" do
      expect(
        scans_for(
          "a.rb" => <<~RUBY
            thing = pick
            class << thing
              class Inner
                @own = {}
              end
            end
          RUBY
        )
      ).to be_empty
    end

    it "flags an unresolved superclass" do
      scans = scans_for(
        "a.rb" => <<~RUBY
          base = Struct.new(:a)
          class Widget < base
          end
        RUBY
      )

      expect(scans.map(&:message))
        .to contain_exactly("unresolved superclass of Widget")
      expect(scans.first).to have_attributes(severity: :warning)
    end

    it "flags an unresolved mixin in a class body" do
      scans = scans_for(
        "a.rb" => <<~RUBY
          class Widget
            include Object.const_get(name)
            extend Kernel.const_get("Helpers")
          end
        RUBY
      )

      expect(scans.map(&:message)).to contain_exactly(
        "unresolved include argument in Widget",
        "unresolved extend argument in Widget"
      )
    end

    # RSpec's include matcher parses as a mixin with a runtime
    # argument. It is the single loudest shape in a spec tree, so
    # the check has to stay out of method and block bodies.
    it "ignores a mixin-shaped call in a block" do
      expect(
        scans_for(
          "a_spec.rb" => <<~RUBY
            RSpec.describe Thing do
              it "works" do
                expect(subject.body).to include("substring")
              end
            end
          RUBY
        )
      ).to be_empty
    end

    it "flags an unresolved path assigned to a constant" do
      scans = scans_for(
        "a.rb" => <<~RUBY
          TABLE = mod::Lookup
        RUBY
      )

      expect(scans.map(&:message))
        .to contain_exactly("unresolved constant path in TABLE")
      expect(scans.first).to have_attributes(severity: :info)
    end

    it "ignores an unresolved path outside an assignment" do
      expect(
        scans_for(
          "a.rb" => <<~RUBY
            def use = mod::Elsewhere
          RUBY
        )
      ).to be_empty
    end

    # rubydex can report the same location twice.
    it "reports one finding per location" do
      expect(
        scans_for(
          "a.rb" => <<~RUBY
            TABLE = mod::Lookup
          RUBY
        ).size
      ).to eq(1)
    end

    it "leaves a line another check already reported alone" do
      sources = {
        "a.rb" => <<~RUBY
          base = Struct.new(:a)
          class Widget < base
          end
        RUBY
      }
      claimed = Audition::Finding.new(
        check: "mutable-constants", severity: :error, message: "x",
        why: "x", fix: "x", path: "a.rb", line: 2
      )

      expect(
        described_class.new
          .analyze_sources(sources, constant_findings: [claimed])
          .select { |f| f.check == "static-scan" }
      ).to be_empty
    end

    # The rule names are rubydex's public labels, and a rename
    # would leave the check silently reporting nothing.
    it "names rules rubydex still ships" do
      shipped = Rubydex::Rules.constants.map(&:to_s)

      expect(shipped)
        .to include(*described_class::SCAN_RULES.keys)
    end
  end
end
