# frozen_string_literal: true

module Audition
  # Severity meanings:
  #   :error:   will raise Ractor::IsolationError (or equivalent) if
  #              this code runs in a non-main Ractor
  #   :warning: raises depending on the value or usage (e.g. reading
  #              class-level ivars is fine for shareable values, fatal
  #              for mutable ones)
  #   :info:    works on Ruby 4.0+, but with caveats worth knowing
  SEVERITIES = {error: 3, warning: 2, info: 1}.freeze

  # A machine-applicable correction: replace source bytes
  # [start_offset...end_offset] with +replacement+. Safety follows
  # the RuboCop convention: :safe edits preserve semantics exactly;
  # :unsafe edits trade a small semantic change for readiness and
  # only apply under --fix-unsafe.
  Autofix = Data.define(
    :start_offset, :end_offset, :replacement, :safety
  ) do
    def initialize(safety: :safe, **rest)
      super
    end

    def unsafe? = safety == :unsafe
  end

  Finding = Data.define(
    :check, :severity, :message, :why, :fix,
    :path, :line, :source, :autofix, :dependency
  ) do
    def initialize(source: nil, autofix: nil, dependency: false,
      **rest)
      super
    end

    def error? = severity == :error

    # True when the problem lives in a dependency's source, not the
    # audited target: real, but not the target's bug to fix.
    def dependency? = dependency

    def fixable? = !autofix.nil?

    def severity_rank = SEVERITIES.fetch(severity)

    def location = line ? "#{path}:#{line}" : path
  end
end
