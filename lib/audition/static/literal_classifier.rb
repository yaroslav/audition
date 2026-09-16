# frozen_string_literal: true

require "prism"

module Audition
  module Static
    # Classifies a Prism expression node by Ractor shareability:
    #   :shareable         proven deeply shareable
    #   :mutable_string    unfrozen String literal
    #   :mutable_container Array/Hash/Set literal or constructor
    #   :mutable_call      unfrozen String, Regexp, or sentinel
    #                      Object returned by a call (`.tr`,
    #                      `format`, `Regexp.new`, `Object.new`)
    #   :shallow_freeze    frozen container with mutable elements
    #   :sync_primitive    Mutex/Queue/... constructor
    #   :proc              lambda or proc
    #   :default_proc      Hash.new with a block; the block
    #                      survives .freeze and stays unshareable
    #   :instance_new      unfrozen instance of an arbitrary class
    #   :opaque_call       method call with an unprovable return
    #   :shallow_opaque    frozen at the top, but what it holds
    #                      is an unprovable call result
    #   :unknown           cannot tell statically
    class LiteralClassifier
      SYNC_PRIMITIVES = %w[
        Mutex Monitor Queue SizedQueue ConditionVariable
        Thread::Mutex Thread::Queue Thread::SizedQueue
        Thread::ConditionVariable
      ].freeze
      SHAREABLE_FACTORIES = %w[Struct Class Module].freeze
      # Sentinels: `NOT_GIVEN = Object.new` raises when read from
      # a worker until frozen, and a frozen bare Object is
      # shareable (verified on Ruby 4.0.6). BasicObject has no
      # #freeze.
      SENTINEL_FACTORIES = %w[Object BasicObject].freeze
      # Concurrent::Map defines no #freeze, so make_shareable
      # raises NoMethodError on it; a constant holding one can
      # never be shared (verified on 4.0.6 with concurrent-ruby).
      UNFREEZABLE_COLLECTIONS = %w[Concurrent::Map].freeze

      # Calls returning a fresh, unfrozen String or Regexp;
      # `# frozen_string_literal: true` covers literals only.
      # Both shapes (`.tr` and `Regexp.new`) turn up in
      # constants in the wild. These names belong
      # to String alone in core, so any receiver qualifies.
      STRING_ONLY_METHODS = %i[
        tr tr_s gsub sub squeeze strip lstrip rstrip chomp chop
        center ljust rjust encode scrub unicode_normalize
      ].freeze
      # Unambiguous only on a String literal receiver: Symbols
      # and numbers define these too and return shareable values.
      STRING_LITERAL_METHODS = %i[
        + * % upcase downcase capitalize swapcase reverse dup
        succ next +@
      ].freeze
      # Array methods that hand back another Array, so a `.join`
      # at the end of the chain still joins the literal it
      # started from (`[MAJOR, MINOR, PRE].compact.join(".")`).
      ARRAY_CHAIN_METHODS = %i[
        compact map collect flatten uniq sort sort_by reverse
        reject select filter flat_map take drop rotate shuffle
        grep grep_v first last
      ].freeze
      FORMATTERS = %i[format sprintf].freeze
      REGEXP_FACTORIES = %i[new union compile].freeze
      # File methods returning a fresh path String.
      FILE_PATH_METHODS = %i[
        expand_path join dirname basename absolute_path realpath
      ].freeze

      # Calls returning a shareable primitive on any receiver.
      SHAREABLE_RETURNS = %i[
        to_i to_int to_f to_r to_c to_sym size length count
        bytesize ord hash
      ].freeze
      # Sorbet's inline casts, which return their value argument.
      SORBET_CASTS = %i[let cast must].freeze

      # @param frozen_string_literal [Boolean] whether the file has
      #   the frozen_string_literal magic comment
      def initialize(frozen_string_literal:)
        @frozen_string_literal = frozen_string_literal
      end

      # @param node [Prism::Node] an expression node
      # @return [Symbol] classification, see class docs
      def classify(node)
        node = begin_value(node)
        case node
        when Prism::IntegerNode, Prism::FloatNode,
             Prism::RationalNode, Prism::ImaginaryNode,
             Prism::SymbolNode, Prism::InterpolatedSymbolNode,
             Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
             Prism::RegularExpressionNode,
             Prism::InterpolatedRegularExpressionNode
          :shareable
        when Prism::StringNode
          @frozen_string_literal ? :shareable : :mutable_string
        when Prism::InterpolatedStringNode
          classify_interpolated_string(node)
        when Prism::ArrayNode, Prism::HashNode,
             Prism::KeywordHashNode
          container_kind(node)
        when Prism::RangeNode
          ends = [node.left, node.right].compact
          if ends.all? { |n| classify(n) == :shareable }
            :shareable
          else
            :unknown
          end
        when Prism::LambdaNode
          :proc
        when Prism::CallNode
          classify_call(node)
        when Prism::IfNode
          ternary_kind(node)
        else
          :unknown
        end
      end

      # The value an expression hands back once begin blocks
      # and inline casts are peeled off.
      def unwrap(node)
        loop do
          inner = begin_value(node)
          inner = cast_value(inner) || inner
          break node if inner.equal?(node)

          node = inner
        end
      end

      # A begin block's value is its last statement. A rescue,
      # else, or ensure clause can supply a different one, so
      # only the plain form resolves.
      def begin_value(node)
        return node unless node.is_a?(Prism::BeginNode) &&
          node.rescue_clause.nil? && node.else_clause.nil? &&
          node.ensure_clause.nil?

        node.statements&.body&.last || node
      end

      # `::Mutex` and `Mutex` are the same constant for matching
      # purposes; the leading colons are stripped.
      def const_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          node.location.slice.delete_prefix("::")
        end
      end

      # The value inside a Sorbet inline cast, or nil. The cast
      # returns its argument, so fixes and type names belong on
      # the value, not the cast.
      def cast_value(node)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless const_name(node.receiver) == "T" &&
          SORBET_CASTS.include?(node.name)

        node.arguments&.arguments&.first
      end

      # What `value.freeze` would classify as, for the check to
      # choose a plain `.freeze` over a deep wrap: :shareable
      # when every element is provably shareable, :shallow_freeze
      # when one is provably mutable, :unknown otherwise.
      def frozen_kind(value)
        case value
        when Prism::ArrayNode, Prism::HashNode,
             Prism::KeywordHashNode
          deep_classify(value.elements)
        when Prism::CallNode
          elements = set_elements(value)
          elements ? deep_classify(elements) : :unknown
        else
          :unknown
        end
      end

      # The Array literal a call chain starts from, when every
      # link keeps it an Array; nil for any other receiver.
      def array_root(node)
        loop do
          case node
          when Prism::ArrayNode
            return node
          when Prism::CallNode
            return nil unless ARRAY_CHAIN_METHODS.include?(node.name)

            node = node.receiver
          else
            return nil
          end
        end
      end

      # The core class whose method a fresh-string call names, for
      # the finding's display: Array#join, Symbol#to_s, String#tr.
      def fresh_string_owner(node)
        receiver = node.receiver
        if node.name == :join && array_root(receiver)
          "Array"
        elsif receiver.is_a?(Prism::SymbolNode)
          "Symbol"
        else
          "String"
        end
      end

      private

      # Adjacent literals ("a" "b") parse as interpolation but
      # compile to one static string, frozen under the magic
      # comment; real interpolation stays mutable.
      def classify_interpolated_string(node)
        static = node.parts.all? do |part|
          part.is_a?(Prism::StringNode)
        end
        if static && @frozen_string_literal
          :shareable
        else
          :mutable_string
        end
      end

      def classify_call(node)
        return :mutable_call if fresh_string?(node) ||
          fresh_regexp?(node)

        receiver = node.receiver
        # `-"str"` interns a frozen copy and `:sym.name` returns
        # the interned frozen String (verified on 4.0.6).
        return :shareable if node.name == :-@ &&
          receiver.is_a?(Prism::StringNode)
        return :shareable if node.name == :name &&
          receiver.is_a?(Prism::SymbolNode)

        case node.name
        when :freeze
          classify_freeze(node, receiver)
        when :new
          name = const_name(receiver)
          return :sync_primitive if SYNC_PRIMITIVES.include?(name) ||
            UNFREEZABLE_COLLECTIONS.include?(name)
          return :shareable if SHAREABLE_FACTORIES.include?(name)
          return :proc if name == "Proc" && node.block
          # Hash.new retains its block as the default proc;
          # Array.new only uses its block to build elements.
          return :default_proc if name == "Hash" && node.block
          return set_kind(node) if name == "Set"
          if SENTINEL_FACTORIES.include?(name)
            bare = node.arguments.nil? && node.block.nil?
            return bare ? :mutable_call : :unknown
          end

          if %w[Hash Array].include?(name)
            return :mutable_container
          end

          name ? :instance_new : :opaque_call
        when :to_set
          set_kind(node)
        when :[]
          index_kind(node)
        when :define
          (const_name(receiver) == "Data") ? :shareable : :unknown
        when :make_shareable
          (const_name(receiver) == "Ractor") ? :shareable : :unknown
        when :lambda, :proc
          (receiver.nil? && node.block) ? :proc : :unknown
        else
          opaque_kind(node)
        end
      end

      # Catch-all for unrecognized calls: shareable returns pass,
      # predicates stay silent, everything else is opaque.
      def opaque_kind(node)
        return :shareable if SHAREABLE_RETURNS.include?(node.name)
        return :unknown if node.name.end_with?("?")

        if (value = cast_value(node))
          return classify(value)
        end

        :opaque_call
      end

      # Indexing into a constant, another call's result, or a
      # fresh instance returns a value of unprovable shareability.
      # Sorbet type constructors and ENV, whose values are frozen
      # strings, stay silent.
      def index_kind(node)
        owner = const_name(node.receiver)
        return set_kind(node) if owner == "Set"
        if owner.nil?
          receiver_kind = classify(node.receiver)
          return :opaque_call if %i[opaque_call instance_new]
            .include?(receiver_kind)
          return :unknown
        end
        return :unknown if owner == "ENV" ||
          owner == "T" || owner.start_with?("T::")

        :opaque_call
      end

      def classify_freeze(node, receiver)
        return :unknown unless node.arguments.nil? && receiver

        case (receiver = begin_value(receiver))
        when Prism::StringNode
          :shareable
        when Prism::ArrayNode, Prism::HashNode
          deep_classify(receiver.elements)
        when Prism::CallNode
          # A default proc survives freezing the Hash; a frozen
          # String or Regexp from a call is deeply shareable.
          case classify(receiver)
          when :default_proc then :default_proc
          when :mutable_call then :shareable
          when :mutable_container then frozen_kind(receiver)
          when :instance_new, :opaque_call then :shallow_opaque
          else :unknown
          end
        else
          :unknown
        end
      end

      def fresh_string?(node)
        receiver = node.receiver
        name = node.name
        # Array#join and Symbol#to_s build a fresh String every
        # call; the magic comment never reaches them (the
        # `[8, 2, 0].join(".")` version string).
        return true if name == :join && array_root(receiver)
        return true if name == :to_s &&
          receiver.is_a?(Prism::SymbolNode)

        case receiver
        when nil
          FORMATTERS.include?(name)
        when Prism::StringNode, Prism::InterpolatedStringNode
          STRING_ONLY_METHODS.include?(name) ||
            STRING_LITERAL_METHODS.include?(name)
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          owner = const_name(receiver)
          (name == :new && owner == "String") ||
            (owner == "Kernel" && FORMATTERS.include?(name)) ||
            (owner == "File" && FILE_PATH_METHODS.include?(name)) ||
            STRING_ONLY_METHODS.include?(name)
        else
          false
        end
      end

      def fresh_regexp?(node)
        REGEXP_FACTORIES.include?(node.name) &&
          const_name(node.receiver) == "Regexp"
      end

      # A container holding a sync primitive can never become
      # shareable; Ractor.make_shareable raises on it (multi_json
      # keeps a frozen Hash of Mutexes). The classification
      # propagates so no freeze or wrap is ever suggested.
      def container_kind(node)
        elements_kind(node.elements)
      end

      def elements_kind(elements)
        sync = elements.any? do |element|
          element_children(element).any? do |child|
            classify(child) == :sync_primitive
          end
        end
        sync ? :sync_primitive : :mutable_container
      end

      # A Set built from literals is a container of them:
      # `Set.new([...])`, `Set[...]`, `%w[...].to_set`. A Set
      # built from an opaque source or a mapping block is still
      # a fresh unfrozen Set, mutable no matter its contents.
      def set_kind(node)
        elements = set_elements(node)
        elements ? elements_kind(elements) : :mutable_container
      end

      def set_elements(node)
        return nil if node.block

        case node.name
        when :new, :[]
          return nil unless const_name(node.receiver) == "Set"

          args = node.arguments&.arguments || []
          return args if node.name == :[]
          return [] if args.empty?
          return nil unless args.size == 1

          args[0].is_a?(Prism::ArrayNode) ? args[0].elements : nil
        when :to_set
          receiver = node.receiver
          return nil unless node.arguments.nil? &&
            receiver.is_a?(Prism::ArrayNode)

          receiver.elements
        end
      end

      def element_children(element)
        case element
        when Prism::AssocNode then [element.key, element.value]
        else [element]
        end
      end

      # A ternary of provable branches classifies as the worst
      # branch: two string literals make a string, so a plain
      # `.freeze` stays available for `cond ? ";" : ":"`.
      def ternary_kind(node)
        return :unknown unless node.subsequent
          .is_a?(Prism::ElseNode)

        branches = [
          single_statement(node.statements),
          single_statement(node.subsequent.statements)
        ]
        return :unknown unless branches.all?

        kinds = branches.map { |branch| classify(branch) }
        return :shareable if kinds.all?(:shareable)

        if kinds.all? { |k| %i[shareable mutable_string].include?(k) }
          :mutable_string
        else
          :unknown
        end
      end

      def single_statement(statements)
        body = statements&.body
        body && body.size == 1 && body[0]
      end

      # Fold element classifications by the strongest evidence:
      # a sync primitive poisons the whole container; a provably
      # mutable element makes it :shallow_freeze; an opaque call
      # result makes it :shallow_opaque. A bare constant read is
      # commonly a class or another frozen constant, so on its
      # own it keeps the container silent (:unknown), but it
      # cannot excuse a bad element elsewhere.
      VERDICT_RANK = {
        shareable: 0, unknown: 1, shallow_opaque: 2,
        shallow_freeze: 3
      }.freeze

      def deep_classify(elements)
        verdict = :shareable
        elements.each do |element|
          element_children(element).each do |child|
            kind =
              case classify(child)
              when :shareable then :shareable
              when :sync_primitive then return :sync_primitive
              when :unknown then :unknown
              when :instance_new, :opaque_call, :shallow_opaque
                :shallow_opaque
              else :shallow_freeze
              end
            if VERDICT_RANK[kind] > VERDICT_RANK[verdict]
              verdict = kind
            end
          end
        end
        verdict
      end
    end
  end
end
