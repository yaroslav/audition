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

  describe "blocks Rails tries to make shareable" do
    it "flags a callback block capturing a mutable local" do
      findings = findings_for(<<~RUBY)
        # frozen_string_literal: true

        class Post < ActiveRecord::Base
          prefix = +"Draft: "
          before_create { title.prepend(prefix) }
        end
      RUBY

      expect(findings.size).to eq(1)
      finding = findings.first
      expect(finding.line).to eq(5)
      expect(finding.severity).to eq(:warning)
      expect(finding.message).to include("before_create")
      expect(finding.message).to include("prefix")
      expect(finding.why).to include("shareable_proc")
      expect(finding.fix).to include("freeze")
    end

    it "accepts a callback capturing a frozen literal" do
      findings = findings_for(<<~RUBY)
        # frozen_string_literal: true

        class Post < ActiveRecord::Base
          prefix = "Draft: "
          count = 3
          before_create { title.prepend(prefix * count) }
        end
      RUBY

      expect(findings).to be_empty
    end

    it "flags a captured local that is assigned twice" do
      findings = findings_for(<<~RUBY)
        # frozen_string_literal: true

        class Post < ActiveRecord::Base
          prefix = "Draft: "
          prefix = "Final: " if published?
          after_save { prefix }
        end
      RUBY

      expect(findings.size).to eq(1)
      expect(findings.first.message).to include("reassigned")
    end

    it "flags Ractor.shareable_proc captures as errors" do
      findings = findings_for(<<~RUBY)
        class Filters
          registry = []
          HANDLER = Ractor.shareable_proc { registry }
          READER = ActiveSupport::Ractors.shareable_lambda { registry }
        end
      RUBY

      expect(findings.map(&:line)).to eq([3, 4])
      expect(findings).to all(have_attributes(severity: :error))
      expect(findings.first.why).to include("IsolationError")
    end

    it "resolves locals assigned inside an included block" do
      findings = findings_for(<<~RUBY)
        module Auditable
          included do
            inner = []
            after_save { inner << id }
          end
        end
      RUBY

      expect(findings.size).to eq(1)
      expect(findings.first.message).to include("inner")
    end

    it "stays quiet on captures it cannot classify" do
      findings = findings_for(<<~RUBY)
        class Post < ActiveRecord::Base
          def self.install(prefix)
            before_save { prefix }
          end

          options = compute_options
          after_save { options }
        end
      RUBY

      expect(findings).to be_empty
    end

    it "ignores blocks on unrelated methods" do
      findings = findings_for(<<~RUBY)
        class Post
          list = []
          %w[a b].each { |name| list << name }
        end
      RUBY

      expect(findings).to be_empty
    end
  end

  # The parallel scan runs every check inside worker Ractors; the
  # capture scanner must stay callable there or the whole scan
  # falls back to serial.
  it "dispatches from a non-main Ractor, as the parallel scan" do
    source = <<~RUBY
      z = [1]
      Ractor.new { z.take(1) }
    RUBY
    Warning[:experimental] = false
    messages = Ractor.new(source) do |code|
      Audition::Static::Analyzer
        .new(checks: [Audition::Static::Checks::RactorIsolation])
        .analyze_source(code, path: "test.rb")
        .map(&:message)
    end.value

    expect(messages.size).to eq(1)
    expect(messages.first).to include("z")
  end
end
