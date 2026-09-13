# frozen_string_literal: true

require "tmpdir"

RSpec.describe Audition::Static::Checks::DependencyClassState do
  around do |example|
    previous = described_class.attributes
    example.run
    described_class.attributes = previous.flat_map do |owner, names|
      names.map { |name| [owner, name] }
    end
  end

  def learn(stub)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kit@1.0.0.rbi")
      File.write(path, stub)
      described_class.learn([path])
      yield
    end
  end

  def findings_for(source)
    Audition::Static::Analyzer.new(checks: [described_class])
      .analyze_source(source, path: "a.rb")
  end

  # The generator's own marker for a method it wrote from an
  # attribute, alongside one that computes its answer.
  let(:attribute_stub) do
    <<~RBI
      # typed: true

      module Kit
        class << self
          # Returns the value of attribute registry.
          #
          # source://kit//lib/kit.rb#9
          def registry; end

          # source://kit//lib/kit.rb#11
          def registry=(value); end

          # Builds a fresh client from the configuration.
          #
          # source://kit//lib/kit.rb#20
          def client; end
        end
      end
    RBI
  end

  it "flags a read of a documented singleton attribute" do
    learn(attribute_stub) do
      findings = findings_for("Kit.registry\n")

      expect(findings.size).to eq(1)
      expect(findings.first).to have_attributes(
        check: "dependency-class-state", line: 1, severity: :warning
      )
      expect(findings.first.message).to include("Kit.registry")
    end
  end

  it "flags a write as an error" do
    learn(attribute_stub) do
      findings = findings_for("Kit.registry = {}\n")

      expect(findings.size).to eq(1)
      expect(findings.first).to have_attributes(
        line: 1, severity: :error
      )
      expect(findings.first.message).to include("Kit.registry=")
    end
  end

  it "leaves a method that computes its answer alone" do
    learn(attribute_stub) do
      expect(findings_for("Kit.client\n")).to be_empty
    end
  end

  it "ignores an attribute on the instance side" do
    stub = <<~RBI
      # typed: true

      module Kit
        # Returns the value of attribute registry.
        #
        # source://kit//lib/kit.rb#9
        def registry; end
      end
    RBI

    learn(stub) do
      expect(findings_for("Kit.registry\n")).to be_empty
    end
  end

  it "matches a nested owner through its full path" do
    stub = <<~RBI
      # typed: true

      module Kit
        class Vault
          class << self
            # Returns the value of attribute store.
            #
            # source://kit//lib/kit/vault.rb#4
            def store; end
          end
        end
      end
    RBI

    learn(stub) do
      findings = findings_for("Kit::Vault.store\nVault.store\n")

      expect(findings.map(&:line)).to contain_exactly(1)
    end
  end

  it "reads nothing from sources that are not stubs" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kit.rb")
      File.write(path, attribute_stub)
      described_class.learn([path])

      expect(findings_for("Kit.registry\n")).to be_empty
    end
  end
end
