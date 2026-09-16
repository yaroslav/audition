# frozen_string_literal: true

RSpec.describe Audition::Static::Checks::InstanceMemoization do
  def findings_for(code)
    analyzer =
      Audition::Static::Analyzer.new(checks: [described_class])
    analyzer.analyze_source(code, path: "test.rb")
  end

  it "flags a lazy memo on a class that freezes itself" do
    findings = findings_for(<<~RUBY)
      class LocalCache
        def initialize(name)
          @name = name
          freeze
        end

        def local_cache_key
          @local_cache_key ||= "\#{@name}_local_cache".to_sym
        end
      end
    RUBY

    expect(findings.size).to eq(1)
    finding = findings.first
    expect(finding.line).to eq(8)
    expect(finding.severity).to eq(:error)
    expect(finding.message).to include("@local_cache_key")
    expect(finding.message).to include("local_cache_key")
    expect(finding.why).to include("FrozenError")
    expect(finding.fix).to include("initialize")
  end

  it "counts make_shareable(self) as freezing" do
    findings = findings_for(<<~RUBY)
      class Zone
        def initialize(tz)
          @tz = tz
          Ractor.make_shareable(self)
        end

        def offset
          return @offset if defined?(@offset)

          @offset = @tz.utc_offset
        end
      end
    RUBY

    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("@offset")
  end

  it "accepts a freeze override that warms the memo first" do
    findings = findings_for(<<~RUBY)
      class Formatter
        def tag_stack
          @thread_key ||= "tags:\#{object_id}"
          IsolatedExecutionState[@thread_key] ||= TagStack.new
        end

        def freeze
          tag_stack
          super
        end
      end
    RUBY

    expect(findings).to be_empty
  end

  it "accepts a freeze override that assigns the memo directly" do
    findings = findings_for(<<~RUBY)
      class Engine
        def app
          @app ||= build_app
        end

        def freeze
          return self if frozen?

          @app = build_app
          @app_build_lock = nil
          super
        end
      end
    RUBY

    expect(findings).to be_empty
  end

  it "follows warming through the methods the override calls" do
    findings = findings_for(<<~RUBY)
      class Result
        def freeze
          indexed_rows
          super
        end

        def indexed_rows
          @indexed_rows ||= rows.map { |row| row.zip(column_indexes) }
        end

        def column_indexes
          @column_indexes ||= columns.each_with_index.to_h
        end
      end
    RUBY

    expect(findings).to be_empty
  end

  it "warns when a freeze override leaves a memo cold" do
    findings = findings_for(<<~RUBY)
      class Formatter
        def tag_stack
          @thread_key ||= "tags:\#{object_id}"
        end

        def pattern
          @pattern ||= Regexp.union(@rules)
        end

        def freeze
          pattern
          super
        end
      end
    RUBY

    expect(findings.size).to eq(1)
    finding = findings.first
    expect(finding.line).to eq(3)
    expect(finding.severity).to eq(:warning)
    expect(finding.message).to include("@thread_key")
    expect(finding.message).to include("freeze")
    expect(finding.fix).to include("super")
  end

  it "stays quiet on classes that never freeze" do
    findings = findings_for(<<~RUBY)
      class Lazy
        def value
          @value ||= compute
        end
      end
    RUBY

    expect(findings).to be_empty
  end

  it "leaves class-level memos to the graph audit" do
    findings = findings_for(<<~RUBY)
      class Registry
        def initialize
          freeze
        end

        def self.all
          @all ||= []
        end

        class << self
          def cache = (@cache ||= {})
        end
      end
    RUBY

    expect(findings).to be_empty
  end

  it "keeps a frozen self out of nested defs and blocks" do
    findings = findings_for(<<~RUBY)
      class Outer
        def initialize
          freeze
        end

        class Inner
          def memo
            @memo ||= 1
          end
        end
      end
    RUBY

    expect(findings).to be_empty
  end
end
