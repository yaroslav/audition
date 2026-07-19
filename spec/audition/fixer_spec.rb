# frozen_string_literal: true

require "tmpdir"

RSpec.describe Audition::Fixer do
  it "applies autofixes bottom-up and reports per-file counts" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "consts.rb")
      File.write(path, <<~RUBY)
        NAME = "audition"
        CACHE = "x"
      RUBY

      findings = Audition::Static::Analyzer.new(
        checks: [Audition::Static::Checks::MutableConstants]
      ).analyze_path(path)
      applied = described_class.new.apply(findings)

      expect(applied).to eq(path => 2)
      expect(File.read(path)).to eq(<<~RUBY)
        NAME = "audition".freeze
        CACHE = "x".freeze
      RUBY
    end
  end

  it "ignores findings without an autofix" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lock.rb")
      File.write(path, "LOCK = Mutex.new\n")

      findings = Audition::Static::Analyzer.new(
        checks: [Audition::Static::Checks::MutableConstants]
      ).analyze_path(path)
      applied = described_class.new.apply(findings)

      expect(applied).to eq({})
      expect(File.read(path)).to eq("LOCK = Mutex.new\n")
    end
  end

  it "skips overlapping edits rather than corrupting the file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.rb")
      File.write(path, "A = [1]\n")
      overlapping = [
        Audition::Finding.new(
          check: "t", severity: :error, message: "m", why: "w",
          fix: "f", path: path, line: 1,
          autofix: Audition::Autofix.new(
            start_offset: 4, end_offset: 7,
            replacement: "Ractor.make_shareable([1])"
          )
        ),
        Audition::Finding.new(
          check: "t", severity: :error, message: "m", why: "w",
          fix: "f", path: path, line: 1,
          autofix: Audition::Autofix.new(
            start_offset: 5, end_offset: 6, replacement: "2"
          )
        )
      ]

      applied = described_class.new.apply(overlapping)

      expect(applied).to eq(path => 1)
      expect(File.read(path))
        .to eq("A = Ractor.make_shareable([1])\n")
    end
  end

  it "orders same-offset inserts by plan position" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "many.rb")
      File.write(path, "ROOT = 1\n")
      findings = (1..48).map do |n|
        Audition::Finding.new(
          check: "t", severity: :error, message: "m", why: "w",
          fix: "f", path: path, line: 1,
          autofix: Audition::Autofix.new(
            start_offset: n % 3, end_offset: n % 3,
            replacement: "<#{n}>"
          )
        )
      end

      described_class.new.apply(findings)

      groups = Hash.new { |h, k| h[k] = [] }
      (1..48).each { |n| groups[n % 3] << "<#{n}>" }
      expected = groups[0].reverse.join + "R" +
        groups[1].reverse.join + "O" +
        groups[2].reverse.join + "OT = 1\n"
      expect(File.read(path)).to eq(expected)
    end
  end
end
