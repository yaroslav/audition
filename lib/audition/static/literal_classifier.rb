# frozen_string_literal: true

require "prism"

module Audition
  module Static
    # Classifies a Prism expression node by Ractor shareability:
    #   :shareable         proven deeply shareable
    #   :mutable_string    unfrozen String literal
    #   :mutable_container Array/Hash literal or constructor
    #   :shallow_freeze    frozen container with mutable elements
    #   :sync_primitive    Mutex/Queue/... constructor
    #   :proc              lambda or proc
    #   :default_proc      Hash.new with a block; the block
    #                      survives .freeze and stays unshareable
    #   :unknown           cannot tell statically
    class LiteralClassifier
      SYNC_PRIMITIVES = %w[
        Mutex Monitor Queue SizedQueue ConditionVariable
        Thread::Mutex Thread::Queue Thread::SizedQueue
        Thread::ConditionVariable
      ].freeze
      SHAREABLE_FACTORIES = %w[Struct Class Module].freeze

      # @param frozen_string_literal [Boolean] whether the file has
      #   the frozen_string_literal magic comment
      def initialize(frozen_string_literal:)
        @frozen_string_literal = frozen_string_literal
      end

      # @param node [Prism::Node] an expression node
      # @return [Symbol] classification, see class docs
      def classify(node)
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
        receiver = node.receiver
        case node.name
        when :freeze
          classify_freeze(node, receiver)
        when :new
          name = const_name(receiver)
          return :sync_primitive if SYNC_PRIMITIVES.include?(name)
          return :shareable if SHAREABLE_FACTORIES.include?(name)
          # Hash.new retains its block as the default proc;
          # Array.new only uses its block to build elements.
          return :default_proc if name == "Hash" && node.block

          if %w[Hash Array].include?(name)
            return :mutable_container
          end

          :unknown
        when :define
          (const_name(receiver) == "Data") ? :shareable : :unknown
        when :make_shareable
          (const_name(receiver) == "Ractor") ? :shareable : :unknown
        when :lambda, :proc
          (receiver.nil? && node.block) ? :proc : :unknown
        else
          :unknown
        end
      end

      def classify_freeze(node, receiver)
        return :unknown unless node.arguments.nil? && receiver

        case receiver
        when Prism::StringNode
          :shareable
        when Prism::ArrayNode, Prism::HashNode
          deep_classify(receiver.elements)
        when Prism::CallNode
          # A default proc survives freezing the Hash.
          (classify(receiver) == :default_proc) ? :default_proc : :unknown
        else
          :unknown
        end
      end

      # A container holding a sync primitive can never become
      # shareable; Ractor.make_shareable raises on it (multi_json
      # keeps a frozen Hash of Mutexes). The classification
      # propagates so no freeze or wrap is ever suggested.
      def container_kind(node)
        sync = node.elements.any? do |element|
          element_children(element).any? do |child|
            classify(child) == :sync_primitive
          end
        end
        sync ? :sync_primitive : :mutable_container
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

      # Fold element classifications: everything provably shareable
      # gives :shareable; anything provably mutable gives
      # :shallow_freeze; a sync primitive poisons the whole
      # container; anything unknowable gives :unknown (stay silent
      # rather than guess).
      def deep_classify(elements)
        verdict = :shareable
        elements.each do |element|
          element_children(element).each do |child|
            case classify(child)
            when :shareable then nil
            when :sync_primitive then return :sync_primitive
            when :unknown then return :unknown
            else verdict = :shallow_freeze
            end
          end
        end
        verdict
      end
    end
  end
end
