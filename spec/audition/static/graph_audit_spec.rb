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
        class Payments
          @registry = {}
          def self.reset! = (@registry = {})
          def pay = (@amount = 1)
        end
      RUBY
      "b.rb" => <<~RUBY
        class Payments
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
    expect(state.first.message).to include("Payments")
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
end
