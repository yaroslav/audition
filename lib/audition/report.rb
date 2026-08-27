# frozen_string_literal: true

module Audition
  # Aggregates static findings and dynamic results into a verdict
  # and the counts the renderers work from. Rendering lives in the
  # Report::Text, Report::Json, and Report::Github classes.
  class Report
    VERDICTS = {
      not_ready: "not ractor-ready",
      blocked: "own code is ractor-ready; blocked by dependencies",
      risky: "risky: warnings only, no hard errors",
      ready: "ractor-ready as far as audition can tell"
    }.freeze

    attr_reader :target_type, :target_root, :findings,
      :dynamic_results, :unsafe_fixes, :baselined

    # @param target_type [Symbol] see {Target#type}
    # @param target_root [String]
    # @param findings [Array<Finding>] static plus dynamic findings
    # @param dynamic_results [Array<Dynamic::Result>]
    # @param unsafe_fixes [Integer] shown as the `--fix-unsafe` hint
    # @param baselined [Integer] findings hidden by the baseline
    def initialize(target_type:, target_root:, findings:,
      dynamic_results: [], unsafe_fixes: 0,
      baselined: 0)
      @target_type = target_type
      @target_root = target_root
      @findings = findings.sort_by do |f|
        [f.path, f.line || 0, -f.severity_rank]
      end
      @dynamic_results = dynamic_results
      @unsafe_fixes = unsafe_fixes
      @baselined = baselined
    end

    # Policy: own errors condemn the target outright; dependency
    # errors (or a failed probe with clean own findings) mean the
    # target is fine but cannot run here yet; anything softer is
    # merely risky.
    #
    # @return [Symbol] `:not_ready`, `:blocked`, `:risky`, or
    #   `:ready`
    def verdict
      return :not_ready if own_errors?
      return :blocked if dependency_errors? ||
        dynamic_results.any? { |r| !r.passed }
      return :risky if counts[:warning].positive?

      # Info notes describe things that work on Ruby 4.0 and are
      # only worth knowing; they do not taint the verdict.
      :ready
    end

    def own_errors?
      counts[:error].positive?
    end

    def dependency_errors?
      counts[:dep_error].positive?
    end

    def counts
      @counts ||= begin
        base = {error: 0, dep_error: 0, warning: 0, info: 0,
                fixable: 0}
        findings.each_with_object(base) do |f, acc|
          if f.error? && f.dependency?
            acc[:dep_error] += 1
          else
            acc[f.severity] += 1
          end
          # Only safe autofixes count: `--fix` alone would not
          # touch an unsafe-only finding, so advertising it as
          # fixable would send users in circles.
          if f.autofix && !f.autofix.unsafe?
            acc[:fixable] += 1
          end
        end
      end
    end
  end
end

require_relative "report/style"
require_relative "report/text"
require_relative "report/json"
require_relative "report/github"
