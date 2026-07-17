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

    def initialize(unsafe: false)
      @unsafe = unsafe
    end

    def apply(findings)
      plans(findings).to_h do |plan|
        File.write(plan.path, patched(plan))
        [plan.path, plan.edits.size]
      end
    end

    # For --dry-run: what would change, without touching anything.
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

        Plan.new(path: path, source: source,
          edits: edits.sort_by { |e| -e.start_offset })
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
          planned += Rewriters::Memoization.plan(file, group)
          planned += Rewriters::WriteOnce.plan(file, group)
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

    def patched(plan)
      source = plan.source.dup
      plan.edits.each do |edit|
        source[edit.start_offset...edit.end_offset] =
          edit.replacement
      end
      source
    end

    def hunks(plan)
      plan.edits.sort_by(&:start_offset).map do |edit|
        line_start =
          if edit.start_offset.zero?
            0
          else
            before = plan.source.rindex("\n", edit.start_offset - 1)
            before ? before + 1 : 0
          end
        line_end = plan.source.index("\n", edit.end_offset) ||
          plan.source.length
        old = plan.source[line_start...line_end]
        updated = old.dup
        span = ((edit.start_offset - line_start)...
                (edit.end_offset - line_start))
        updated[span] = edit.replacement
        {
          line: plan.source[0, edit.start_offset].count("\n") + 1,
          old: old,
          new: updated.chomp
        }
      end
    end
  end
end
