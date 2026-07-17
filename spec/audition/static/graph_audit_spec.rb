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
