# frozen_string_literal: true

module Audition
  class Report
    # Terminal renderer; styles stay injectable so pipes and
    # --plain degrade cleanly.
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
