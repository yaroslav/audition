# frozen_string_literal: true

require "json"

module Audition
  class Report
    # Machine-readable renderer for CI pipelines and --compare.
    class Json
      def initialize(report)
        @report = report
      end

      def render
        JSON.pretty_generate(
          "audition" => VERSION,
          "ruby" => RUBY_VERSION,
          "target" => {"type" => @report.target_type.to_s,
                       "root" => @report.target_root},
          "verdict" => @report.verdict.to_s,
          "summary" => summary,
          "findings" => findings,
          "dynamic" => dynamic
        )
      end

      private

      def summary
        counts = @report.counts
        {
          "errors" => counts[:error],
          "dependency_errors" => counts[:dep_error],
          "warnings" => counts[:warning],
          "infos" => counts[:info],
          "fixable" => counts[:fixable]
        }
      end

      def findings
        @report.findings.map do |f|
          {
            "check" => f.check,
            "severity" => f.severity.to_s,
            "message" => f.message,
            "why" => f.why,
            "fix" => f.fix,
            "path" => f.path,
            "line" => f.line,
            "source" => f.source,
            "fixable" => f.fixable?,
            "dependency" => f.dependency?
          }
        end
      end

      def dynamic
        @report.dynamic_results.map do |r|
          {"mode" => r.mode.to_s, "passed" => r.passed,
           "raw" => r.raw}
        end
      end
    end
  end
end
