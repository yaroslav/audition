# frozen_string_literal: true

require "prism"

module Audition
  module Static
    # A parsed Ruby file plus the magic comments that change Ractor
    # semantics.
    class SourceFile
      attr_reader :path, :source, :parse_result

      def self.read(path)
        new(source: File.read(path), path: path)
      end

      def initialize(source:, path:)
        @source = source
        @path = path
        @parse_result = Prism.parse(source)
      end

      def valid_syntax? = parse_result.success?

      def syntax_errors = parse_result.errors

      def root = parse_result.value

      def magic_comment(key)
        comment = parse_result.magic_comments.find do |mc|
          mc.key_loc.slice == key
        end
        comment&.value_loc&.slice
      end

      # String literals in this file are frozen (and therefore
      # shareable when they contain no interpolation).
      def frozen_string_literal?
        magic_comment("frozen_string_literal") == "true"
      end

      # `# shareable_constant_value: literal|experimental_everything|
      # experimental_copy` makes constant values deeply frozen and
      # shareable at parse time, so constant checks are moot.
      # (v1 treats the comment as file-wide.)
      def shareable_constants?
        value = magic_comment("shareable_constant_value")
        !value.nil? && value != "none"
      end

      def line_at(number)
        @lines ||= source.lines
        @lines[number - 1]&.strip
      end

      # Literal feature strings required by top-level statements.
      def top_level_requires
        @top_level_requires ||= root.statements.body.filter_map do |s|
          next unless s.is_a?(Prism::CallNode) && s.receiver.nil?
          next unless %i[require require_relative].include?(s.name)

          arg = s.arguments&.arguments&.first
          arg.unescaped if arg.is_a?(Prism::StringNode)
        end
      end

      # Where a hoisted `require` line can be inserted: right after
      # the last existing top-level require, or after the leading
      # comment block (shebang and magic comments), or at the top.
      def boot_insertion
        last_require = root.statements.body.rfind do |s|
          s.is_a?(Prism::CallNode) && s.receiver.nil? &&
            %i[require require_relative].include?(s.name)
        end
        if last_require
          newline = raw.index("\n", last_require.location.end_offset)
          offset = newline ? newline + 1 : raw.bytesize
          {offset: offset, after_require: true}
        else
          {offset: leading_comments_end, after_require: false}
        end
      end

      # Prism reports byte offsets; index math against the source
      # must run on a binary copy or multibyte content shifts
      # every computed position.
      def raw
        @raw ||= source.dup.force_encoding(Encoding::BINARY)
      end

      # Method names that read as in-place data mutation when
      # sent to a constant. Shared by the mutable-constants check
      # and the fixers: a constant this file mutates is a
      # deliberate accumulator (sinatra's PARAMS_CONFIG) and must
      # never be frozen by magic comment or wrap.
      CONST_MUTATORS = %i[
        []= << push unshift concat merge! replace
      ].freeze

      # @return [Array<String>] names of constants that receive a
      #   mutator call somewhere in this file
      def mutated_constants
        @mutated_constants ||= begin
          names = []
          queue = [root]
          until queue.empty?
            node = queue.shift
            queue.concat(node.child_nodes.compact)
            next unless node.is_a?(Prism::CallNode)
            next unless CONST_MUTATORS.include?(node.name)

            case node.receiver
            when Prism::ConstantReadNode
              names << node.receiver.name.to_s
            when Prism::ConstantPathNode
              names << node.receiver.location.slice
            end
          end
          names.uniq
        end
      end

      # Keys Ruby actually honors. Prism reports every comment
      # shaped like `# key: value`, which sweeps up documentation
      # (`# I18n.t: 'date.formats.short'`); inserting after those
      # would land a magic comment mid-file.
      MAGIC_KEYS = %w[
        encoding coding frozen_string_literal
        shareable_constant_value warn_indent
      ].freeze

      # Where a new magic comment can go: after the shebang and any
      # existing magic comments, before code.
      def magic_insertion_offset
        offset = 0
        if raw.start_with?("#!")
          newline = raw.index("\n")
          offset = newline ? newline + 1 : raw.bytesize
        end
        after_magic = parse_result.magic_comments.filter_map do |mc|
          next unless MAGIC_KEYS.include?(mc.key_loc.slice)

          newline = raw.index("\n", mc.value_loc.end_offset)
          newline ? newline + 1 : raw.bytesize
        end.max
        [offset, after_magic || 0].max
      end

      def leading_comments_end
        offset = 0
        source.each_line do |line|
          break unless line.start_with?("#")

          offset += line.bytesize
        end
        offset
      end
    end
  end
end
