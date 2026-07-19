# frozen_string_literal: true

require "tmpdir"

RSpec.describe Audition::Directives do
  def finding(path:, line:, check: "global-variables")
    Audition::Finding.new(
      check: check, severity: :error, message: "m", why: "w",
      fix: "f", path: path, line: line
    )
  end

  it "suppresses findings on lines with matching pragmas" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.rb")
      File.write(path, <<~RUBY)
        $a = 1 # audition:disable global-variables
        $b = 2 # audition:disable
        $c = 3 # audition:disable class-variables
        $d = 4
      RUBY

      findings = (1..4).map { |line| finding(path: path, line: line) }
      kept = described_class.new.filter(findings)

      expect(kept.map(&:line)).to eq([3, 4])
    end
  end

  it "ignores pragma-shaped text inside string literals" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.rb")
      File.write(path, <<~RUBY)
        $a = "usage:  # audition:disable global-variables "
      RUBY

      kept = described_class.new.filter([finding(path: path, line: 1)])

      expect(kept.map(&:line)).to eq([1])
    end
  end

  it "honors every pragma on a line" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "m.rb")
      File.write(path, <<~RUBY)
        $a = 1 # audition:disable unsafe-calls # audition:disable global-variables
      RUBY

      kept = described_class.new.filter([finding(path: path, line: 1)])

      expect(kept).to be_empty
    end
  end

  it "supports comma-separated check lists" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.rb")
      File.write(path,
        "$a = 1 # audition:disable foo, global-variables\n")

      kept = described_class.new.filter([finding(path: path, line: 1)])

      expect(kept).to be_empty
    end
  end

  it "keeps findings without a path, line, or file" do
    findings = [
      finding(path: "missing.rb", line: 1),
      finding(path: "label-only", line: nil)
    ]

    expect(described_class.new.filter(findings)).to eq(findings)
  end
end
