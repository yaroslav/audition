# frozen_string_literal: true

RSpec.describe Audition::Static::Checks::RuntimeRequire do
  def findings_for(code)
    analyzer =
      Audition::Static::Analyzer.new(checks: [described_class])
    analyzer.analyze_source(code, path: "test.rb")
  end

  it "flags require inside a method body with a hoist autofix" do
    code = <<~RUBY
      # frozen_string_literal: true

      def load_json
        require "json"
        JSON
      end
    RUBY
    findings = findings_for(code)

    expect(findings.size).to eq(1)
    finding = findings.first
    expect(finding.severity).to eq(:warning)
    expect(finding.why).to include("main Ractor")
    expect(finding.autofix.safety).to eq(:unsafe)

    fix = finding.autofix
    fixed = code.dup
    fixed[fix.start_offset...fix.end_offset] = fix.replacement
    expect(fixed).to eq(<<~RUBY)
      # frozen_string_literal: true

      require "json"

      def load_json
        require "json"
        JSON
      end
    RUBY
  end

  it "does not flag features already required at top level" do
    findings = findings_for(<<~RUBY)
      require "json"

      def load_json
        require "json"
        JSON
      end
    RUBY

    expect(findings).to be_empty
  end

  it "offers no hoist for rescue-guarded optional requires" do
    findings = findings_for(<<~RUBY)
      def load_data
        require "tzinfo/data"
        true
      rescue LoadError
        false
      end
    RUBY

    expect(findings.size).to eq(1)
    expect(findings.none?(&:fixable?)).to be(true)
  end

  it "offers no hoist for load or dynamic features" do
    findings = findings_for(<<~RUBY)
      def a = load("y.rb")
      def b = require(feature_name)
    RUBY

    expect(findings.size).to eq(2)
    expect(findings.none?(&:fixable?)).to be(true)
  end

  it "gives autoload an eager require appended at file end" do
    Dir.mktmpdir do |dir|
      code = <<~RUBY
        module Backend
          autoload :Base, "base"
        end
      RUBY
      path = File.join(dir, "backend.rb")
      File.write(path, code)
      File.write(File.join(dir, "base.rb"), "module Base; end\n")

      finding = Audition::Static::Analyzer.new(
        checks: [described_class]
      ).analyze_path(path).first

      expect(finding.autofix.safety).to eq(:unsafe)
      fix = finding.autofix
      fixed = code.dup
      fixed[fix.start_offset...fix.end_offset] = fix.replacement
      expect(fixed).to eq(<<~RUBY)
        module Backend
          autoload :Base, "base"
        end
        require "base"
      RUBY
    end
  end

  it "withholds the autofix for optional-dependency autoloads" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "backend.rb")
      File.write(path, <<~RUBY)
        module Backend
          autoload :KeyValue, "key_value"
          autoload :External, "some_gem"
        end
      RUBY
      File.write(File.join(dir, "key_value.rb"), <<~RUBY)
        begin
          require "oj"
        rescue LoadError
          require "json"
        end
      RUBY

      findings = Audition::Static::Analyzer.new(
        checks: [described_class]
      ).analyze_path(path)

      expect(findings.size).to eq(2)
      expect(findings.none?(&:fixable?)).to be(true)
    end
  end

  it "leaves autoload alone when the feature is required eagerly" do
    findings = findings_for(<<~RUBY)
      module Backend
        autoload :JSON, "json"
      end
      require "json"
    RUBY

    expect(findings).to be_empty
  end

  it "flags require_relative and load inside methods" do
    findings = findings_for(<<~RUBY)
      def a = require_relative("x")
      def b = load("y.rb")
    RUBY

    expect(findings.map(&:line)).to eq([1, 2])
  end

  it "does not flag top-level requires" do
    expect(findings_for('require "json"')).to be_empty
  end

  it "does not flag calls with an explicit receiver" do
    expect(findings_for("def a = loader.require('x')")).to be_empty
  end

  it "flags autoload anywhere" do
    findings = findings_for('autoload :JSON, "json"')

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("autoload")
  end
end
