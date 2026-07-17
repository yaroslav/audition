# frozen_string_literal: true

RSpec.describe Audition::Static::Checks::UnsafeCalls do
  def findings_for(code)
    analyzer =
      Audition::Static::Analyzer.new(checks: [described_class])
    analyzer.analyze_source(code, path: "test.rb")
  end

  it "flags Ractor.yield as removed in Ruby 4.0" do
    findings = findings_for("Ractor.yield(42)")

    expect(findings.size).to eq(1)
    expect(findings.first.severity).to eq(:error)
    expect(findings.first.fix).to include("Ractor::Port")
  end

  it "flags Rails class-level attribute macros" do
    findings = findings_for(<<~RUBY)
      class Config
        class_attribute :settings
        cattr_accessor :cache
        thread_mattr_accessor :context
      end
    RUBY

    expect(findings.size).to eq(3)
    expect(findings).to all(have_attributes(severity: :error))
    expect(findings.first.why).to include("class-level")
  end

  it "flags include Singleton" do
    findings = findings_for(<<~RUBY)
      class Registry
        include Singleton
      end
    RUBY

    expect(findings.size).to eq(1)
    expect(findings.first.severity).to eq(:warning)
  end

  it "flags ObjectSpace._id2ref" do
    findings = findings_for("ObjectSpace._id2ref(id)")

    expect(findings.size).to eq(1)
    expect(findings.first.severity).to eq(:warning)
  end

  it "notes process-global APIs at info level" do
    findings = findings_for(<<~RUBY)
      at_exit { cleanup }
      Signal.trap("TERM") { stop }
      ENV["MODE"] = "worker"
    RUBY

    expect(findings.map(&:line)).to eq([1, 2, 3])
    expect(findings).to all(have_attributes(severity: :info))
  end

  it "does not flag ENV reads" do
    expect(findings_for('ENV["HOME"]')).to be_empty
  end

  it "does not flag unrelated calls that share names with receivers" do
    expect(findings_for("scope.yield(42)\nrecord.trap")).to be_empty
  end
end
