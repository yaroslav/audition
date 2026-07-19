# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Audition::BundleSweep do
  def write_lockfile(dir, specs)
    lock = File.join(dir, "Gemfile.lock")
    File.write(lock, <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
      #{specs.map { |s| "    #{s}" }.join("\n")}

      PLATFORMS
        ruby

      DEPENDENCIES
      #{specs.map { |s| "  #{s[/\S+/]}" }.join("\n")}
    LOCK
    lock
  end

  it "audits every locked gem and ranks the results" do
    Dir.mktmpdir do |dir|
      # rspec is always installed here: it is running this spec.
      version = Gem::Specification.find_by_name("rspec").version
      lock = write_lockfile(dir,
        ["rspec (#{version})", "no-such-gem-xyz (1.0.0)"])

      rows = described_class.new(
        lockfile: lock, static_only: true
      ).rows

      expect(rows.map(&:name))
        .to contain_exactly("rspec", "no-such-gem-xyz")

      rspec_row = rows.find { |r| r.name == "rspec" }
      expect(rspec_row.verdict).to eq(:not_ready)
      expect(rspec_row.errors).to be_positive
      expect(rspec_row.status).to eq("ok")

      missing = rows.find { |r| r.name == "no-such-gem-xyz" }
      expect(missing.status).to eq("not installed")
      expect(missing.verdict).to be_nil
    end
  end

  it "audits the installed spec of the locked version" do
    Dir.mktmpdir do |dir|
      lock = write_lockfile(dir, ["mygem (1.2.3)"])
      gem_root = File.join(dir, "mygem-1.2.3")
      FileUtils.mkdir_p(File.join(gem_root, "lib"))
      File.write(File.join(gem_root, "lib", "bad.rb"), "$x = 1\n")
      spec = instance_double(Gem::Specification,
        name: "mygem", gem_dir: gem_root, require_paths: ["lib"])
      allow(Gem::Specification).to receive(:find_by_name)
        .with("mygem", "1.2.3").and_return(spec)

      rows = described_class.new(
        lockfile: lock, static_only: true
      ).rows

      row = rows.find { |r| r.name == "mygem" }
      expect(row.version).to eq("1.2.3")
      expect(row.verdict).to eq(:not_ready)
      expect(row.errors).to be_positive
      expect(row.status).to eq("ok")
    end
  end

  it "honors directives and per-gem config like a direct audit" do
    Dir.mktmpdir do |dir|
      lock = write_lockfile(dir, ["mygem (1.2.3)"])
      gem_root = File.join(dir, "mygem-1.2.3")
      lib = File.join(gem_root, "lib")
      FileUtils.mkdir_p(File.join(lib, "skip"))
      File.write(File.join(lib, "pragma.rb"),
        "$a = 1 # audition:disable global-variables\n")
      File.write(File.join(lib, "consts.rb"), "NAME = \"x\"\n")
      File.write(File.join(lib, "skip", "hidden.rb"),
        "$boom = 1\n")
      File.write(File.join(gem_root, ".audition.yml"), <<~YAML)
        exclude:
          - lib/skip/**
        checks:
          disable:
            - mutable-constants
      YAML
      spec = instance_double(Gem::Specification,
        name: "mygem", gem_dir: gem_root, require_paths: ["lib"])
      allow(Gem::Specification).to receive(:find_by_name)
        .with("mygem", "1.2.3").and_return(spec)

      rows = described_class.new(
        lockfile: lock, static_only: true
      ).rows

      row = rows.find { |r| r.name == "mygem" }
      expect(row.errors).to eq(0)
      expect(row.warnings).to eq(0)
      expect(row.verdict).to eq(:ready)
    end
  end

  it "turns unexpected per-gem failures into a failed row" do
    Dir.mktmpdir do |dir|
      lock = write_lockfile(dir, ["mygem (1.2.3)"])
      allow(Gem::Specification).to receive(:find_by_name)
        .and_raise(RuntimeError, "boom")

      rows = described_class.new(
        lockfile: lock, static_only: true
      ).rows

      row = rows.find { |r| r.name == "mygem" }
      expect(row.status).to eq("failed: RuntimeError")
      expect(row.verdict).to be_nil
    end
  end
end
