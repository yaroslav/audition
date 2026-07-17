# frozen_string_literal: true

require "prism"

module Audition
  module Static
    # Classifies a Prism expression node by Ractor shareability:
    #   :shareable         proven deeply shareable
    #   :mutable_string    unfrozen String literal
    #   :mutable_container Array/Hash literal
    #   :shallow_freeze    frozen container with mutable elements
    #   :sync_primitive    Mutex/Queue/... constructor
    #   :proc              lambda or proc
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
          :mutable_container
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
        else
          :unknown
        end
      end

      def const_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then node.location.slice
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
        else
          :unknown
        end
      end

      # Fold element classifications: everything provably shareable
      # gives :shareable; anything provably mutable gives
      # :shallow_freeze; anything unknowable gives :unknown (stay
      # silent rather than guess).
      def deep_classify(elements)
        verdict = :shareable
        elements.each do |element|
          children =
            case element
            when Prism::AssocNode then [element.key, element.value]
            else [element]
            end
          children.each do |child|
            case classify(child)
            when :shareable then nil
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
