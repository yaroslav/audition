# frozen_string_literal: true

require_relative "rewriters"

module Audition
  # Applies machine-generated corrections (rubocop-style --fix).
  # Two tiers: safe inline autofixes attached to findings, and,
  # under unsafe: true, file-level rewrites planned by
  # Audition::Rewriters. Byte offsets come from Prism, so edits are
  # applied bottom-up to keep earlier offsets valid.
  class Fixer
    Plan = Data.define(:path, :source, :edits)

    # @param unsafe [Boolean] also apply `:unsafe` autofixes and
    #   the multi-site rewriters
    def initialize(unsafe: false)
      @unsafe = unsafe
    end

    # Applies planned edits to the files on disk.
    #
    # @param findings [Array<Finding>]
    # @return [Hash{String => Integer}] path => applied edit count
    def apply(findings)
      plans(findings).to_h do |plan|
        File.write(plan.path, patched(plan))
        [plan.path, plan.edits.size]
      end
    end

    # For `--dry-run`: what would change, without touching anything.
    #
    # @param findings [Array<Finding>]
    # @return [Array<Hash>] per file: `:path` and `:hunks`
    #   (`:line`, `:old`, `:new`)
    def preview(findings)
      plans(findings).map do |plan|
        {path: plan.path, hunks: hunks(plan)}
      end
    end

    def edit_count(findings)
      plans(findings).sum { |plan| plan.edits.size }
    end

    # How many additional edits the unsafe tier would unlock; used
    # for the "N more with --fix-unsafe" summary hint.
    #
    # @param findings [Array<Finding>]
    # @return [Integer]
    def self.unsafe_gain(findings)
      new(unsafe: true).edit_count(findings) -
        new(unsafe: false).edit_count(findings)
    end

    def plans(findings)
      findings.group_by(&:path).filter_map do |path, group|
        next unless path && File.file?(path)

        source = File.read(path)
        edits = build_edits(path, source, group)
        next if edits.empty?

        # Applied bottom-up; the explicit index keeps same-offset
        # inserts in plan order (sort_by is not stable).
        ordered = edits.each_with_index.sort_by do |edit, index|
          [-edit.start_offset, index]
        end.map(&:first)
        Plan.new(path: path, source: source, edits: ordered)
      end
    end

    private

    def build_edits(path, source, group)
      magic = nil
      planned = []
      if @unsafe
        file = Static::SourceFile.new(source: source, path: path)
        if file.valid_syntax?
          magic = Rewriters::MagicComments.plan(file, group)
          planned = Rewriters.resolve(
            Rewriters::Memoization.plan(file, group) +
            Rewriters::WriteOnce.plan(file, group)
          )
        end
      end

      inline = group.filter_map do |finding|
        autofix = finding.autofix
        next unless autofix
        next if autofix.unsafe? && !@unsafe
        next if magic && magic[:covers].include?(finding.check)

        autofix
      end
      inline << magic[:edit] if magic
      accept_non_overlapping(inline + planned)
    end

    # First edit wins on overlap.
    def accept_non_overlapping(edits)
      accepted = []
      edits.each do |edit|
        overlap = accepted.any? do |other|
          edit.start_offset < other.end_offset &&
            other.start_offset < edit.end_offset
        end
        accepted << edit unless overlap
      end
      accepted
    end

    # Prism offsets are byte offsets; splicing must happen on a
    # binary copy or every edit after the first multibyte
    # character lands short (addressable's unicode tables were
    # the crash test).
    def patched(plan)
      encoding = plan.source.encoding
      bytes = plan.source.dup.force_encoding(Encoding::BINARY)
      plan.edits.each do |edit|
        bytes[edit.start_offset...edit.end_offset] =
          edit.replacement.dup.force_encoding(Encoding::BINARY)
      end
      bytes.force_encoding(encoding)
    end

    # Edits whose line windows overlap (a guard deletion runs into
    # the write it pairs with) render as one hunk, so the preview
    # never repeats a line in two half-applied states. All window
    # math runs on a binary copy: the offsets are bytes.
    def hunks(plan)
      encoding = plan.source.encoding
      raw = plan.source.dup.force_encoding(Encoding::BINARY)
      groups = []
      plan.edits.sort_by(&:start_offset).each do |edit|
        from, upto = line_window(raw, edit)
        if groups.any? && from <= groups.last[:upto]
          last = groups.last
          last[:upto] = [last[:upto], upto].max
          last[:edits] << edit
        else
          groups << {from: from, upto: upto, edits: [edit]}
        end
      end
      groups.map do |group|
        old = raw[group[:from]...group[:upto]]
        updated = old.dup
        group[:edits].reverse_each do |edit|
          span = ((edit.start_offset - group[:from])...
                  (edit.end_offset - group[:from]))
          updated[span] =
            edit.replacement.dup.force_encoding(Encoding::BINARY)
        end
        {
          line: raw[0, group[:from]].count("\n") + 1,
          old: old.force_encoding(encoding),
          new: updated.chomp.force_encoding(encoding)
        }
      end
    end

    def line_window(raw, edit)
      from =
        if edit.start_offset.zero?
          0
        else
          before = raw.rindex("\n", edit.start_offset - 1)
          before ? before + 1 : 0
        end
      upto = raw.index("\n", edit.end_offset) || raw.length
      [from, upto]
    end
  end
end
