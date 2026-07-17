# frozen_string_literal: true

RSpec.describe Audition::Report do
  def finding(severity: :error, path: "lib/a.rb", line: 3,
    autofix: nil, check: "global-variables",
    dependency: false)
    Audition::Finding.new(
      check: check,
      severity: severity,
      message: "read of global variable $x",
      why: "Non-main Ractors cannot access global variables.",
      fix: "Pass the value into the Ractor explicitly.",
      path: path,
      line: line,
      source: "$x + 1",
      autofix: autofix,
      dependency: dependency
    )
  end

  def report_for(findings, dynamic: [])
    described_class.new(
      target_type: :script,
      target_root: "/tmp/app",
      findings: findings,
      dynamic_results: dynamic
    )
  end

  describe "#verdict" do
    it "is not_ready when any error exists" do
      expect(report_for([finding]).verdict).to eq(:not_ready)
    end

    it "is risky when only warnings and infos exist" do
      findings = [finding(severity: :warning),
        finding(severity: :info)]
      expect(report_for(findings).verdict).to eq(:risky)
    end

    it "is blocked when only dependencies have errors" do
      findings = [finding(dependency: true),
        finding(severity: :warning)]
      expect(report_for(findings).verdict).to eq(:blocked)
    end

    it "is not_ready when own errors exist alongside dep errors" do
      findings = [finding, finding(dependency: true)]
      expect(report_for(findings).verdict).to eq(:not_ready)
    end

    it "is ready when nothing was found" do
      expect(report_for([]).verdict).to eq(:ready)
    end

    it "is blocked when a dynamic probe failed without findings" do
      failed = Audition::Dynamic::Result.new(
        mode: :rack, raw: {}, findings: [], passed: false
      )
      expect(report_for([], dynamic: [failed]).verdict)
        .to eq(:blocked)
    end
  end

  describe "text format" do
    it "renders glyphs, colors, and an OSC 8 file hyperlink" do
      style = Audition::Report::Style.new(
        color: true, hyperlinks: true
      )
      text = report_for([finding]).to_text(style: style)

      expect(text).to include("✖")
      expect(text).to include("\e[")
      expect(text).to include("\e]8;;file://")
      expect(text).to include("lib/a.rb:3")
      expect(text).to include("not ractor-ready")
    end

    it "renders plain ASCII when styling is off" do
      style = Audition::Report::Style.new(
        color: false, hyperlinks: false
      )
      text = report_for([finding]).to_text(style: style)

      expect(text).not_to include("\e[")
      expect(text).not_to include("\e]8")
      expect(text).to include("lib/a.rb:3")
      expect(text).to include("why:")
      expect(text).to include("fix:")
    end

    it "mentions available unsafe fixes in the summary" do
      style = Audition::Report::Style.new(
        color: false, hyperlinks: false
      )
      report = described_class.new(
        target_type: :script,
        target_root: "/tmp/app",
        findings: [finding],
        unsafe_fixes: 3
      )

      expect(report.to_text(style: style))
        .to include("3 more with --fix-unsafe")
    end

    it "counts fixable findings in the summary" do
      fixable = finding(
        autofix: Audition::Autofix.new(
          start_offset: 0, end_offset: 0, replacement: ".freeze"
        )
      )
      style = Audition::Report::Style.new(
        color: false, hyperlinks: false
      )
      text = report_for([fixable]).to_text(style: style)

      expect(text).to match(/1 fixable/)
    end
  end

  describe "github format" do
    it "emits workflow command annotations" do
      out = report_for([finding]).to_github

      expect(out).to include(
        "::error file=lib/a.rb,line=3,title=audition " \
        "global-variables::"
      )
      expect(out).to include("read of global variable $x")
      expect(out).not_to include("\n::error file=lib/a.rb\n")
      expect(out).to include("verdict")
    end
  end

  describe "json format" do
    it "serializes findings, summary, and verdict" do
      json = JSON.parse(report_for([finding]).to_json)

      expect(json["verdict"]).to eq("not_ready")
      expect(json["summary"]["errors"]).to eq(1)
      expect(json["findings"].first["check"])
        .to eq("global-variables")
      expect(json["findings"].first["line"]).to eq(3)
      expect(json["findings"].first["dependency"]).to be(false)
    end

    it "splits dependency errors out in the summary" do
      json = JSON.parse(
        report_for([finding(dependency: true)]).to_json
      )

      expect(json["verdict"]).to eq("blocked")
      expect(json["summary"]["errors"]).to eq(0)
      expect(json["summary"]["dependency_errors"]).to eq(1)
    end
  end
end
