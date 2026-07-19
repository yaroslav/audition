# frozen_string_literal: true

require "json"
require "pastel"
require "tty/link"

module Audition
  # Aggregates static findings and dynamic results into a verdict and
  # renders them as npm-CLI-style text or JSON.
  class Report
    # ANSI + OSC 8 styling with graceful degradation. Color and
    # hyperlinks are decided once, at construction; pass color: false
    # for pipes, NO_COLOR, or dumb terminals.
    class Style
      GLYPHS = Ractor.make_shareable(
        {
          error: ["✖", "x"], warning: ["⚠", "!"],
          info: ["ℹ", "i"], pass: ["✔", "ok"],
          section: ["◆", "*"], fix: ["✎", "+"]
        }
      )

      PAINTS = %i[red yellow green cyan magenta dim bold].freeze

      def self.detect(io: $stdout)
        on = io.respond_to?(:tty?) && io.tty? &&
          !ENV.key?("NO_COLOR") && ENV["TERM"] != "dumb"
        new(color: on, hyperlinks: on && TTY::Link.link?)
      end

      def initialize(color:, hyperlinks:)
        @pastel = Pastel.new(enabled: color)
        @color = color
        @hyperlinks = hyperlinks
      end

      def glyph(kind)
        GLYPHS.fetch(kind)[@color ? 0 : 1]
      end

      PAINTS.each do |name|
        define_method(name) do |text| # audition:disable unsafe-calls
          @pastel.public_send(name, text)
        end
      end

      def severity_color(severity, text)
        case severity
        when :error then red(text)
        when :warning then yellow(text)
        else cyan(text)
        end
      end

      # OSC 8 hyperlink wrapping "path:line" display text in a
      # file:// URI; supporting terminals make it clickable.
      # tty-link emits when it detects support; when hyperlinks are
      # forced on despite no detection (tests, --force scenarios)
      # fall back to the raw OSC 8 template, since tty-link's
      # fallback is "text -> url" prose.
      def link(text, absolute_path)
        return text unless @hyperlinks

        uri = "file://#{absolute_path}"
        if TTY::Link.link?
          TTY::Link.link_to(text, uri)
        else
          "\e]8;;#{uri}\e\\#{text}\e]8;;\e\\"
        end
      end
    end

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

    # @param style [Style] rendering style (auto-detected default)
    # @return [String] the human-facing terminal report
    def to_text(style: Style.detect)
      Text.new(self, style).render
    end

    GITHUB_LEVELS = {
      error: "error", warning: "warning", info: "notice"
    }.freeze

    # GitHub Actions workflow commands: findings become inline PR
    # annotations when this runs in CI.
    #
    # @return [String] one `::error`/`::warning`/`::notice` line
    #   per finding plus a verdict line
    def to_github
      lines = findings.map do |f|
        level = GITHUB_LEVELS.fetch(f.severity)
        location = f.line ? ",line=#{f.line}" : ""
        body = workflow_escape("#{f.message}. #{f.why}")
        file = property_escape(f.path)
        title = property_escape("audition #{f.check}")
        "::#{level} file=#{file}#{location}," \
        "title=#{title}::#{body}"
      end
      lines << "audition verdict: #{VERDICTS.fetch(verdict)}"
      lines.join("\n")
    end

    def to_json(*)
      JSON.pretty_generate(
        "audition" => VERSION,
        "ruby" => RUBY_VERSION,
        "target" => {"type" => target_type.to_s,
                     "root" => target_root},
        "verdict" => verdict.to_s,
        "summary" => {
          "errors" => counts[:error],
          "dependency_errors" => counts[:dep_error],
          "warnings" => counts[:warning],
          "infos" => counts[:info],
          "fixable" => counts[:fixable]
        },
        "findings" => findings.map do |f|
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
        end,
        "dynamic" => dynamic_results.map do |r|
          {"mode" => r.mode.to_s, "passed" => r.passed,
           "raw" => r.raw}
        end
      )
    end

    private

    def workflow_escape(text)
      text.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
    end

    # Workflow command properties additionally reserve `:` and `,`;
    # an unescaped comma in a path would end the property early.
    def property_escape(text)
      workflow_escape(text).gsub(":", "%3A").gsub(",", "%2C")
    end

    public

    # Text renderer, kept separate from the data so styles stay
    # injectable.
    class Text
      WRAP = 74

      def initialize(report, style)
        @report = report
        @style = style
      end

      def render
        [header, *file_sections, *dynamic_section, summary]
          .join("\n")
      end

      private

      def header
        s = @style
        title = s.bold("audition #{VERSION}")
        meta = s.dim(
          "ruby #{RUBY_VERSION} · #{@report.target_type} at " \
          "#{@report.target_root}"
        )
        "#{s.glyph(:section)} #{title} #{meta}\n"
      end

      def file_sections
        @report.findings.group_by(&:path).map do |path, findings|
          lines = [@style.bold("  #{path}")]
          findings.each { |f| lines.concat(finding_lines(f)) }
          lines.join("\n") + "\n"
        end
      end

      def finding_lines(finding)
        s = @style
        glyph = s.severity_color(finding.severity,
          s.glyph(finding.severity))
        loc = location_label(finding)
        fix_mark = finding.fixable? ? " #{s.cyan(s.glyph(:fix))}" : ""
        dep_mark =
          finding.dependency? ? " #{s.dim("(dependency)")}" : ""
        head = "    #{glyph} #{loc}#{finding.message}" \
               "#{fix_mark}#{dep_mark} #{s.dim(finding.check)}"
        [head,
          *annotation("why", finding.why),
          *annotation("fix", finding.fix)]
      end

      def location_label(finding)
        return "" unless finding.line

        s = @style
        text = "#{finding.path}:#{finding.line}"
        absolute = File.expand_path(finding.path, @report.target_root)
        "#{s.cyan(s.link(text, absolute))}  "
      end

      def annotation(label, content)
        return [] if content.nil? || content.empty?

        wrapped = wrap("#{label}: #{content}", WRAP - 6)
        wrapped.map { |line| "      #{@style.dim(line)}" }
      end

      # Tokens longer than the width (long URLs) cannot end before
      # whitespace, so the first alternative would drop their head;
      # the second hard-slices them instead.
      def wrap(text, width)
        text.scan(/\S.{0,#{width - 1}}(?=\s|\z)|\S{#{width}}/m)
      end

      def dynamic_section
        return [] if @report.dynamic_results.empty?

        s = @style
        lines = [s.bold("  dynamic probes")]
        @report.dynamic_results.each do |result|
          lines << if result.passed
            "    #{s.green(s.glyph(:pass))} " \
            "#{result.mode} probe passed inside a Ractor"
          else
            "    #{s.red(s.glyph(:error))} " \
            "#{result.mode} probe failed " \
            "#{s.dim("(details above)")}"
          end
        end
        [lines.join("\n") + "\n"]
      end

      def pluralize(count, noun)
        (count == 1) ? "#{count} #{noun}" : "#{count} #{noun}s"
      end

      def summary
        s = @style
        c = @report.counts
        parts = []
        if c[:error].positive?
          parts << s.red(pluralize(c[:error], "error"))
        end
        if c[:dep_error].positive?
          parts << s.magenta(
            pluralize(c[:dep_error], "dependency error")
          )
        end
        if c[:warning].positive?
          parts << s.yellow(pluralize(c[:warning], "warning"))
        end
        parts << s.cyan("#{c[:info]} info") if c[:info].positive?
        if c[:fixable].positive?
          parts << s.cyan(
            "#{c[:fixable]} fixable #{s.glyph(:fix)} " \
            "(run with --fix)"
          )
        end
        if @report.unsafe_fixes.positive?
          parts << s.cyan(
            pluralize(@report.unsafe_fixes, "edit") +
            " with --fix-unsafe"
          )
        end
        if @report.baselined.positive?
          parts << s.dim("#{@report.baselined} baselined")
        end
        parts << s.green("no findings") if parts.empty?

        verdict = @report.verdict
        glyph, paint =
          case verdict
          when :not_ready then [:error, :red]
          when :blocked then [:warning, :magenta]
          when :risky then [:warning, :yellow]
          else [:pass, :green]
          end
        badge = s.public_send(paint,
          "#{s.glyph(glyph)} " +
          VERDICTS.fetch(verdict))
        "  summary: #{parts.join(" · ")}\n" \
        "  verdict: #{s.bold(badge)}\n"
      end
    end
  end
end
