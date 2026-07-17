# frozen_string_literal: true

RSpec.describe Audition::Static::Checks::Base do
  let(:toy_check) do
    Class.new(described_class) do
      check_name "toy"

      explain :spotted,
        severity: :warning,
        message: "ivar %{name} spotted",
        why: "because %{name} is watched",
        fix: "remove %{name}"

      on :instance_variable_read_node do |node|
        flag(node, :spotted, name: node.name)
      end
    end
  end

  def file_for(code)
    Audition::Static::SourceFile.new(source: code, path: "t.rb")
  end

  it "flags through the message catalog with interpolation" do
    findings = toy_check.call(file_for("@a\n"))

    expect(findings.size).to eq(1)
    finding = findings.first
    expect(finding.check).to eq("toy")
    expect(finding.severity).to eq(:warning)
    expect(finding.message).to eq("ivar @a spotted")
    expect(finding.why).to eq("because @a is watched")
    expect(finding.fix).to eq("remove @a")
  end

  it "keeps traversing children after a hit" do
    findings = toy_check.call(file_for("x = [@a, [@b, foo(@c)]]\n"))

    expect(findings.map(&:message)).to contain_exactly(
      "ivar @a spotted", "ivar @b spotted", "ivar @c spotted"
    )
  end

  it "raises on unknown catalog keys" do
    broken = Class.new(described_class) do
      check_name "broken"
      on(:instance_variable_read_node) { |n| flag(n, :nope) }
    end

    expect { broken.call(file_for("@a\n")) }
      .to raise_error(KeyError)
  end

  it "supports third-party check registration" do
    Audition::Static::Checks.register(toy_check)
    expect(Audition::Static::Checks.all).to include(toy_check)
  ensure
    Audition::Static::Checks.deregister(toy_check)
    expect(Audition::Static::Checks.all).not_to include(toy_check)
  end
end
