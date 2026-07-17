# frozen_string_literal: true

RSpec.describe Audition::Static::Checks::GlobalVariables do
  def findings_for(code)
    analyzer =
      Audition::Static::Analyzer.new(checks: [described_class])
    analyzer.analyze_source(code, path: "test.rb")
  end

  it "flags a global variable read as an error" do
    findings = findings_for(<<~RUBY)
      def config
        $app_config
      end
    RUBY

    expect(findings.size).to eq(1)
    finding = findings.first
    expect(finding.check).to eq("global-variables")
    expect(finding.severity).to eq(:error)
    expect(finding.line).to eq(2)
    expect(finding.message).to include("$app_config")
    expect(finding.why).to include("Ractor::IsolationError")
    expect(finding.fix).not_to be_empty
  end

  it "flags global variable writes, including operator and or-writes" do
    findings = findings_for(<<~RUBY)
      $counter = 0
      $counter += 1
      $cache ||= {}
    RUBY

    expect(findings.map(&:line)).to eq([1, 2, 3])
    expect(findings).to all(have_attributes(severity: :error))
  end

  it "does not flag ractor-local special globals like $stdout and $~" do
    findings = findings_for(<<~RUBY)
      $stdout.puts "hi"
      $stderr.puts "err"
      $stdin.gets
      raise "x" rescue $!
      "abc" =~ /b/ ? $~ : $_
    RUBY

    expect(findings).to be_empty
  end

  it "does not flag regexp capture pseudo-globals ($1, $&)" do
    findings = findings_for(<<~RUBY)
      "abc" =~ /(b)/
      [$1, $&, $`, $'].compact
    RUBY

    expect(findings).to be_empty
  end

  it "allows ractor-local writes to $VERBOSE and $DEBUG" do
    findings = findings_for(<<~RUBY)
      old, $VERBOSE = $VERBOSE, nil
      $DEBUG = false
      $VERBOSE = old
    RUBY

    expect(findings).to be_empty
  end

  it "allows reading $$" do
    expect(findings_for("puts $$")).to be_empty
  end

  it "gives $LOAD_PATH a load-path-specific explanation" do
    findings = findings_for('$LOAD_PATH.unshift("lib")')

    expect(findings.size).to eq(1)
    expect(findings.first.why).to include("load path")
  end
end
