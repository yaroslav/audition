# frozen_string_literal: true

module Audition
  class Report
    # GitHub Actions renderer: workflow-command annotations that
    # land on the PR diff, plus a markdown table for the job
    # summary page ($GITHUB_STEP_SUMMARY).
    class Github
      LEVELS = {
        error: "error", warning: "warning", info: "notice"
      }.freeze

      def initialize(report)
        @report = report
      end

      # @return [String] one `::error`/`::warning`/`::notice` line
      #   per finding plus a verdict line
      def render
        lines = @report.findings.map { |f| annotation(f) }
        lines <<
          "audition verdict: #{VERDICTS.fetch(@report.verdict)}"
        lines.join("\n")
      end

      # @return [String] verdict heading plus a counts table
      def summary
        c = @report.counts
        <<~MARKDOWN
          ## audition: #{VERDICTS.fetch(@report.verdict)}

          | findings | count |
          | --- | --- |
          | errors | #{c[:error]} |
          | dependency errors | #{c[:dep_error]} |
          | warnings | #{c[:warning]} |
          | info | #{c[:info]} |
          | fixable | #{c[:fixable]} |
        MARKDOWN
      end

      private

      def annotation(f)
        level = LEVELS.fetch(f.severity)
        location = f.line ? ",line=#{f.line}" : ""
        body = workflow_escape("#{f.message}. #{f.why}")
        # Annotations anchor to workspace-relative paths; a `./`
        # prefix (from `audition .`) keeps them off the diff.
        file = property_escape(f.path.delete_prefix("./"))
        title = property_escape("audition #{f.check}")
        "::#{level} file=#{file}#{location}," \
        "title=#{title}::#{body}"
      end

      def workflow_escape(text)
        text.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      end

      # Workflow command properties additionally reserve `:` and
      # `,`; an unescaped comma in a path would end the property
      # early.
      def property_escape(text)
        workflow_escape(text).gsub(":", "%3A").gsub(",", "%2C")
      end
    end
  end
end
