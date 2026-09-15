# frozen_string_literal: true

require "tmpdir"

RSpec.describe Audition::Config do
  def write_config(dir, content)
    File.write(File.join(dir, ".audition.yml"), content)
  end

  describe ".load" do
    it "rejects non-mapping YAML with a clear error" do
      Dir.mktmpdir do |dir|
        write_config(dir, "just a string\n")

        expect { described_class.load(dir) }.to raise_error(
          Audition::Error, /expected a YAML mapping/
        )
      end
    end

    it "rejects an unknown fail_on level" do
      Dir.mktmpdir do |dir|
        write_config(dir, "fail_on: sometimes\n")

        expect { described_class.load(dir) }.to raise_error(
          Audition::Error, /fail_on must be/
        )
      end
    end

    it "accepts every valid fail_on level" do
      Dir.mktmpdir do |dir|
        %w[error warning info never].each do |level|
          write_config(dir, "fail_on: #{level}\n")

          config = described_class.load(dir)

          expect(config.fail_on).to eq(level.to_sym)
        end
      end
    end

    it "defaults test_dirs to the conventional three" do
      Dir.mktmpdir do |dir|
        write_config(dir, "fail_on: warning\n")

        expect(described_class.load(dir).test_dirs)
          .to eq(Audition::Target::TEST_DIRS)
      end
    end

    it "replaces test_dirs rather than adding to them" do
      Dir.mktmpdir do |dir|
        write_config(dir, "test_dirs:\n  - qa\n  - checks\n")

        expect(described_class.load(dir).test_dirs)
          .to eq(%w[qa checks])
      end
    end

    it "honors an empty test_dirs list" do
      Dir.mktmpdir do |dir|
        write_config(dir, "test_dirs: []\n")

        expect(described_class.load(dir).test_dirs).to eq([])
      end
    end

    it "rejects a test_dirs entry that is a path" do
      Dir.mktmpdir do |dir|
        write_config(dir, "test_dirs:\n  - qa/unit\n")

        expect { described_class.load(dir) }.to raise_error(
          Audition::Error, /without slashes/
        )
      end
    end
  end

  describe "#excluded?" do
    def config(*patterns)
      described_class.new(
        fail_on: nil, timeout: nil, exclude: patterns,
        disabled_checks: []
      )
    end

    it "keeps single-star globs within one directory" do
      expect(config("db/*.rb").excluded?("db/schema.rb"))
        .to be(true)
      expect(config("db/*.rb").excluded?("db/migrate/deep.rb"))
        .to be(false)
    end

    it "matches ./-prefixed patterns" do
      expect(config("./db/**").excluded?("db/migrate/deep.rb"))
        .to be(true)
    end

    it "still excludes whole trees via dir/**" do
      expect(config("legacy/**").excluded?("legacy/a/b.rb"))
        .to be(true)
    end

    it "supports brace alternation" do
      expect(config("{db,log}/*.rb").excluded?("db/schema.rb"))
        .to be(true)
      expect(config("{db,log}/*.rb").excluded?("app/x.rb"))
        .to be(false)
    end
  end
end
