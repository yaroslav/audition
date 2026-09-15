# frozen_string_literal: true

require "tmpdir"

RSpec.describe Audition::Static::Checks::UnshareableReads do
  def findings_for(code)
    analyzer =
      Audition::Static::Analyzer.new(checks: [described_class])
    analyzer.analyze_source(code, path: "test.rb")
  end

  it "flags every read site of T::Boolean" do
    findings = findings_for(<<~RUBY)
      class Widget
        sig { returns(T::Boolean) }
        def ready?
          @ready = T.let(compute, T::Boolean)
        end
      end
    RUBY

    expect(findings.size).to eq(2)
    expect(findings.map(&:line)).to eq([2, 4])
    expect(findings).to all(have_attributes(severity: :warning))
    expect(findings.first.message).to include("T::Boolean")
    expect(findings.first.why).to include("sig blocks")
  end

  it "matches the fully qualified form" do
    findings = findings_for("x = ::T::Boolean\n")

    expect(findings.size).to eq(1)
  end

  it "leaves other Sorbet constants alone" do
    findings = findings_for(<<~RUBY)
      sig { params(items: T::Array[String]).void }
      def go(items); end
    RUBY

    expect(findings).to be_empty
  end

  describe "dynamic constants" do
    after { described_class.dynamic = [] }

    it "flags value reads under a learned namespace" do
      described_class.dynamic = [%w[Kit Vault]]
      findings = findings_for(<<~RUBY)
        token = Kit::Vault::API_TOKEN
        client = Kit::Vault::Client.new
      RUBY

      expect(findings.map(&:line)).to eq([1])
      expect(findings.first.message).to include("API_TOKEN")
      expect(findings.first.why).to include("const_set")
    end

    it "learns namespaces that const_set computed names" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "vault.rb"), <<~RUBY)
          module Vault
            class << self
              def load(data)
                data.each { |name, value| const_set(name, value) }
              end
            end
          end
        RUBY

        described_class.learn(Dir.glob(File.join(dir, "*")))

        expect(described_class.dynamic).to eq([%w[Vault]])
      end
    end

    it "ignores const_set with a literal name" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "kit.rb"), <<~RUBY)
          module Kit
            const_set(:VERSION, "1.0")
          end
        RUBY

        described_class.learn(Dir.glob(File.join(dir, "*")))

        expect(described_class.dynamic).to be_empty
      end
    end
  end

  describe "learned aliases" do
    after { described_class.learned = [] }

    it "flags learned aliases read in type positions" do
      described_class.learned = [%w[Kit Widget RowType]]
      findings = findings_for(<<~RUBY)
        class Builder
          sig { params(row: RowType).void }
          def go(row)
            T.cast(fetch, Kit::Widget::RowType)
          end
        end
      RUBY

      expect(findings.map(&:line)).to eq([2, 4])
      expect(findings.first.message).to include("RowType")
    end

    it "leaves a same-named constant outside type positions alone" do
      described_class.learned = [%w[Kit RowType]]
      findings = findings_for(<<~RUBY)
        row = RowType.new
        T.let(RowType.parse(raw), String)
      RUBY

      expect(findings).to be_empty
    end

    it "requires the read to line up with the definition's tail" do
      described_class.learned = [%w[Kit RowType]]
      findings = findings_for(<<~RUBY)
        sig { returns(Other::RowType) }
        def row; end
      RUBY

      expect(findings).to be_empty
    end

    it "learns definitions from swept files" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "kit.rbi"), <<~RUBY)
          Kit::RowType = T.type_alias { T::Hash[Symbol, Symbol] }
        RUBY
        File.write(File.join(dir, "widget.rb"), <<~RUBY)
          module Kit
            ColType = T.type_alias do
              T::Array[String]
            end
          end
        RUBY

        described_class.learn(Dir.glob(File.join(dir, "*")))
        findings = findings_for(<<~RUBY)
          sig { params(row: Kit::RowType, col: ColType).void }
          def go(row, col); end
        RUBY

        expect(findings.size).to eq(2)
      end
    end
  end
end
