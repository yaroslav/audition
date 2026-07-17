# frozen_string_literal: true

module Audition
  # Severity ranks, higher is worse. Meanings:
  #
  # - `:error`: will raise `Ractor::IsolationError` (or equivalent)
  #   if this code runs in a non-main Ractor
  # - `:warning`: raises depending on the value or usage (e.g.
  #   reading class-level ivars is fine for shareable values, fatal
  #   for mutable ones)
  # - `:info`: works on Ruby 4.0+, but with caveats worth knowing
  #
  # @return [Hash{Symbol => Integer}]
  SEVERITIES = {error: 3, warning: 2, info: 1}.freeze

  # A machine-applicable correction: replace source bytes
  # `start_offset...end_offset` with `replacement`. Safety follows
  # the RuboCop convention: `:safe` edits preserve semantics
  # exactly; `:unsafe` edits trade a small semantic change for
  # Ractor-readiness and only apply under `--fix-unsafe`.
  #
  # @!attribute [r] start_offset
  #   @return [Integer] byte offset where the edit begins
  # @!attribute [r] end_offset
  #   @return [Integer] byte offset where the edit ends (exclusive)
  # @!attribute [r] replacement
  #   @return [String] text spliced over the range
  # @!attribute [r] safety
  #   @return [Symbol] `:safe` or `:unsafe`
  Autofix = Data.define(
    :start_offset, :end_offset, :replacement, :safety
  ) do
    def initialize(safety: :safe, **rest)
      super
    end

    # @return [Boolean] whether this edit needs `--fix-unsafe`
    def unsafe? = safety == :unsafe
  end

  # One diagnosed problem: what was found (`message`), the Ractor
  # rule it violates (`why`), what to write instead (`fix`), where
  # (`path`/`line`/`source`), and optionally a machine-applicable
  # {Autofix}. Produced by static checks, the graph audit, and the
  # dynamic prober alike.
  #
  # @!attribute [r] check
  #   @return [String] kebab-case check identifier
  # @!attribute [r] severity
  #   @return [Symbol] `:error`, `:warning`, or `:info`
  # @!attribute [r] message
  #   @return [String] one-line statement of the problem
  # @!attribute [r] why
  #   @return [String] the Ractor rule behind the finding
  # @!attribute [r] fix
  #   @return [String] suggested remediation
  # @!attribute [r] path
  #   @return [String] file path, or a label for runtime findings
  # @!attribute [r] line
  #   @return [Integer, nil] 1-based line, nil for whole-target
  # @!attribute [r] source
  #   @return [String, nil] the offending source line, stripped
  # @!attribute [r] autofix
  #   @return [Autofix, nil] machine-applicable correction
  # @!attribute [r] dependency
  #   @return [Boolean] see {#dependency?}
  Finding = Data.define(
    :check, :severity, :message, :why, :fix,
    :path, :line, :source, :autofix, :dependency
  ) do
    def initialize(source: nil, autofix: nil, dependency: false,
      **rest)
      super
    end

    # @return [Boolean] whether severity is `:error`
    def error? = severity == :error

    # True when the problem lives in a dependency's source, not the
    # audited target: real, but not the target's bug to fix.
    #
    # @return [Boolean]
    def dependency? = dependency

    # @return [Boolean] whether an {Autofix} is attached
    def fixable? = !autofix.nil?

    # @return [Integer] rank from {SEVERITIES}, higher is worse
    def severity_rank = SEVERITIES.fetch(severity)

    # @return [String] "path:line", or just the path label
    def location = line ? "#{path}:#{line}" : path
  end
end
