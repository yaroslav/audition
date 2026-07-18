# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Audition::CLI do
  def run(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = described_class.run(argv, stdout: stdout,
      stderr: stderr)
    [status, stdout.string, stderr.string]
  end

  it "audits a hostile script: findings, verdict, exit 1" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.rb")
      File.write(path, "$boom = 1\n")

      status, out, = run(path)

      expect(status).to eq(1)
      expect(out).to include("write to global variable $boom")
      expect(out).to include("why:")
      expect(out).to include("not ractor-ready")
    end
  end

  it "passes a clean script with exit 0" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ok.rb")
      File.write(path, "puts [1, 2].sum\n")

      status, out, = run(path)

      expect(status).to eq(0)
      expect(out).to include("ractor-ready")
    end
  end

  it "emits machine-readable JSON with --format json" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.rb")
      File.write(path, "class B\n  @@x = 1\nend\n")

      status, out, = run(path, "--format", "json", "--static-only")

      expect(status).to eq(1)
      json = JSON.parse(out)
      expect(json["verdict"]).to eq("not_ready")
      expect(json["findings"]).not_to be_empty
    end
  end

  it "applies safe corrections with --fix and reports them" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "consts.rb")
      File.write(path, "NAME = \"x\"\n")

      status, out, = run(path, "--fix", "--static-only")

      expect(File.read(path)).to eq("NAME = \"x\".freeze\n")
      expect(out).to include("fixed 1")
      expect(status).to eq(0)
    end
  end

  it "advertises unsafe fixes in the summary" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "memo.rb")
      File.write(path, <<~RUBY)
        class Store
          def self.config = (@config ||= { "a" => 1 })
        end
      RUBY

      _, out, = run(path, "--static-only")

      expect(out).to match(/\d+ more with --fix-unsafe/)
    end
  end

  it "applies unsafe rewrites with --fix-unsafe" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "memo.rb")
      File.write(path, <<~RUBY)
        class Store
          def self.config = (@config ||= { "a" => 1 })
        end
      RUBY

      status, out, = run(path, "--fix-unsafe", "--static-only")

      content = File.read(path)
      expect(content).to include('def self.config = ({ "a" => 1 })')
      expect(content).not_to include("@config")
      expect(out).to include("fixed 1")
      expect(status).to eq(0)
    end
  end

  it "previews without writing under --fix --dry-run" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "consts.rb")
      source = "NAME = \"x\"\n"
      File.write(path, source)

      status, out, = run(path, "--fix", "--dry-run",
        "--static-only")

      expect(File.read(path)).to eq(source)
      expect(out).to include("dry run")
      expect(out).to include('NAME = "x".freeze')
      expect(status).to eq(1)
    end
  end

  it "honors inline disable pragmas end to end" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ok.rb")
      File.write(path,
        "$flag = 1 # audition:disable global-variables\n")

      status, = run(path, "--static-only")

      expect(status).to eq(0)
    end
  end

  it "reads fail_on and exclude from .audition.yml" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "legacy"))
      File.write(File.join(dir, "app.rb"),
        "def l = require \"json\"\n")
      File.write(File.join(dir, "legacy", "bad.rb"), "$x = 1\n")
      File.write(File.join(dir, ".audition.yml"), <<~YAML)
        fail_on: warning
        exclude:
          - legacy/**
      YAML

      status, out, = run(dir, "--static-only")
      overridden, = run(dir, "--static-only", "--fail-on", "error")

      expect(out).not_to include("legacy/bad.rb")
      expect(status).to eq(1)
      expect(overridden).to eq(0)
    end
  end

  it "supports the baseline adoption workflow" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.rb")
      File.write(path, "$x = 1\n")

      first, out, = run(dir, "--write-baseline", "--static-only")
      expect(first).to eq(0)
      expect(out).to include("baseline written")
      expect(File).to exist(File.join(dir, ".audition-baseline.json"))

      clean, clean_out, = run(dir, "--static-only")
      expect(clean).to eq(0)
      expect(clean_out).to include("1 baselined")

      File.write(path, "$x = 1\n$y = 2\n")
      regressed, = run(dir, "--static-only")
      expect(regressed).to eq(1)

      ignored, = run(dir, "--static-only", "--no-baseline")
      expect(ignored).to eq(1)
    end
  end

  it "sweeps a Gemfile.lock into a per-gem verdict table" do
    Dir.mktmpdir do |dir|
      lock = File.join(dir, "Gemfile.lock")
      File.write(lock, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rspec (3.13.2)

        PLATFORMS
          ruby

        DEPENDENCIES
          rspec
      LOCK

      status, out, = run(lock, "--static-only")

      expect(out).to include("rspec")
      expect(out).to include("not ready")
      expect(status).to eq(1)
    end
  end

  it "reports finding deltas with --compare" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "app.rb")
      File.write(path, "$a = 1\n$b = 2\n")
      _, old_json, = run(path, "--static-only", "--format", "json")
      old_path = File.join(dir, "old.json")
      File.write(old_path, old_json)

      File.write(path, "$b = 2\n$c = 3\n")
      _, out, = run(path, "--static-only", "--compare", old_path)

      expect(out).to include("1 fixed")
      expect(out).to include("1 introduced")
      expect(out).to include("$c")
    end
  end

  it "prints the capability table with --capabilities" do
    status, out, = run("--capabilities")

    expect(status).to eq(0)
    expect(out).to include("global variable read")
    expect(out).to include("Ractor::IsolationError")
    expect(out).to include("ENV read")
  end

  it "fails with exit 2 and usage on bad targets" do
    status, _, err = run("no-such-thing-at-all")

    expect(status).to eq(2)
    expect(err).to include("not a file, directory")
  end

  it "honors --fail-on warning" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "warny.rb")
      File.write(path, "def l = require \"json\"\n")

      default_status, = run(path, "--static-only")
      strict_status, = run(path, "--static-only",
        "--fail-on", "warning")

      expect(default_status).to eq(0)
      expect(strict_status).to eq(1)
    end
  end
end
