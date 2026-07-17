# frozen_string_literal: true

RSpec.describe Audition::Static::Checks::RactorIsolation do
  def findings_for(code)
    analyzer =
      Audition::Static::Analyzer.new(checks: [described_class])
    analyzer.analyze_source(code, path: "test.rb")
  end

  it "flags Ractor.new blocks that capture outer locals" do
    findings = findings_for(<<~RUBY)
      z = [1]
      limit = 5
      Ractor.new { z.take(limit) }
    RUBY

    expect(findings.size).to eq(1)
    finding = findings.first
    expect(finding.severity).to eq(:error)
    expect(finding.message).to include("z")
    expect(finding.message).to include("limit")
    expect(finding.why).to include("ArgumentError")
    expect(finding.fix).to include("Ractor.new(")
  end

  it "accepts values passed as Ractor arguments" do
    findings = findings_for(<<~RUBY)
      z = [1]
      Ractor.new(z) { |z| z.sum }
    RUBY

    expect(findings).to be_empty
  end

  it "allows nested blocks using the Ractor block's own locals" do
    findings = findings_for(<<~RUBY)
      Ractor.new do
        total = 0
        [1, 2].each { |n| total += n }
        total
      end
    RUBY

    expect(findings).to be_empty
  end

  it "flags outer captures reached from nested blocks" do
    findings = findings_for(<<~RUBY)
      offset = 10
      Ractor.new do
        [1, 2].map { |n| n + offset }
      end
    RUBY

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("offset")
  end

  it "ignores defs inside the block (fresh scopes)" do
    findings = findings_for(<<~RUBY)
      x = 1
      Ractor.new do
        def helper(x) = x * 2
        helper(2)
      end
    RUBY

    expect(findings).to be_empty
  end

  it "ignores other receivers named new" do
    findings = findings_for(<<~RUBY)
      z = 1
      Thread.new { z }
    RUBY

    expect(findings).to be_empty
  end
end
