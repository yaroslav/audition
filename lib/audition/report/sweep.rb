# frozen_string_literal: true

require "json"
require "table_tennis"

module Audition
  class Report
    # Renders a bundle sweep. Its unit is a gem rather than a
    # finding, so it gets its own renderer instead of bending
    # Report around a shape it does not have.
    class Sweep
      CELLS = {
        :not_ready => "not ready", :blocked => "blocked",
        :risky => "risky", :ready => "ready", nil => "-"
      }.freeze

      # The severity glyphs the text report uses, so a verdict
      # reads the same in a cell as it does in a summary.
      GLYPHS = {
        not_ready: :error, blocked: :warning,
        risky: :warning, ready: :pass
      }.freeze

      # Foreground only, and applied to the whole row: a
      # background fill reads as a bar across the table, and a
      # painted cell would widen its column by the invisible
      # length of its own escape sequence. Ready gems keep the
      # default color, so what is colored is what needs reading.
      PAINTS = Ractor.make_shareable({
        :not_ready => [:red], :blocked => [:magenta],
        :risky => [:yellow], nil => [:faint]
      })

      TITLE = "Audition bundle sweep"

      # @param rows [Array<BundleSweep::Row>] one per locked gem
      # @param style [Style] palette for the text rendering
      def initialize(rows, style)
        @rows = rows
        @style = style
      end

      # @param table_opts [Hash] what the terminal supports; see
      #   the caller for why color cannot be detected here
      # @return [String] the table plus a summary line
      def render(**table_opts)
        table = TableTennis.new(cells, title: TITLE, mark: paint,
          **table_opts)
        "#{table}\n#{summary}"
      end

      def json
        JSON.pretty_generate(
          "audition" => VERSION,
          "ruby" => RUBY_VERSION,
          "bundle" => @rows.map { |r| json_row(r) }
        )
      end

      # Sweep rows carry no file or line, so annotations land on
      # the run summary rather than a diff.
      # @return [String] annotation lines plus a summary line
      def annotations
        lines = @rows.filter_map do |row|
          level = annotation_level(row)
          next unless level

          "::#{level} title=Audition::gem #{row.name} " \
          "#{row.version}: #{row.errors} errors, " \
          "#{row.dep_errors} dependency errors, " \
          "#{row.warnings} warnings (#{CELLS.fetch(row.verdict)})"
        end
        (lines << plain_summary).join("\n")
      end

      # @return [String] job summary page table for Actions
      def markdown
        lines = [
          "## #{TITLE}", "",
          "| gem | version | verdict | errors | dep errors " \
          "| warnings | fixable |",
          "| --- | --- | --- | --- | --- | --- | --- |"
        ]
        @rows.each do |r|
          lines << "| #{r.name} | #{r.version} | " \
            "#{CELLS.fetch(r.verdict)} | #{r.errors} | " \
            "#{r.dep_errors} | #{r.warnings} | #{r.fixable} |"
        end
        lines.push("", plain_summary).join("\n")
      end

      private

      def cells
        @rows.map do |r|
          {
            "gem" => r.name,
            "version" => r.version,
            "verdict" => verdict_cell(r.verdict),
            "errors" => clean_as_blank(r.errors),
            "dep errors" => clean_as_blank(r.dep_errors),
            "warnings" => clean_as_blank(r.warnings),
            "fixable" => clean_as_blank(r.fixable),
            "status" => r.status
          }
        end
      end

      def verdict_cell(verdict)
        cell = CELLS.fetch(verdict)
        glyph = GLYPHS[verdict]
        glyph ? "#{@style.glyph(glyph)} #{cell}" : cell
      end

      # A clean count is the common case across hundreds of gems;
      # leaving it to the table's placeholder keeps the eye on the
      # rows that carry something.
      def clean_as_blank(count)
        count.positive? ? count : nil
      end

      # The table gem hands the lambda back the row it was given,
      # which carries the gem but not the verdict symbol.
      def paint
        paints = @rows.to_h do |r|
          [[r.name, r.version], PAINTS[r.verdict]]
        end
        ->(row) { paints[[row["gem"], row["version"]]] }
      end

      def summary
        glyph, paint = if blockers.positive?
          [:error, :red]
        elsif ready == @rows.size
          [:pass, :green]
        else
          [:warning, :yellow]
        end
        head = @style.public_send(paint,
          "#{@style.glyph(glyph)} #{plain_summary}")
        return head if blockers.zero?

        "#{head} #{@style.dim("· #{blockers} not ready")}"
      end

      def plain_summary
        "#{ready} of #{@rows.size} gems ractor-ready"
      end

      def ready
        @ready ||= @rows.count { |r| r.verdict == :ready }
      end

      def blockers
        @blockers ||= @rows.count { |r| r.verdict == :not_ready }
      end

      def annotation_level(row)
        if row.verdict == :not_ready ||
            (row.errors + row.dep_errors).positive?
          "error"
        elsif row.warnings.positive?
          "warning"
        end
      end

      def json_row(row)
        {
          "gem" => row.name,
          "version" => row.version,
          "verdict" => row.verdict&.to_s,
          "errors" => row.errors,
          "dependency_errors" => row.dep_errors,
          "warnings" => row.warnings,
          "infos" => row.infos,
          "fixable" => row.fixable,
          "status" => row.status
        }
      end
    end
  end
end
