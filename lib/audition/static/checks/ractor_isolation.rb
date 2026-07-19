# frozen_string_literal: true

module Audition
  module Static
    module Checks
      # Ractor.new verifies block isolation at creation time: a
      # block that touches locals from the enclosing scope raises
      # ArgumentError before the Ractor ever runs. Prism records the
      # resolution depth of every local reference, so captures are
      # detectable exactly: a reference whose depth reaches past the
      # Ractor block's own scope is an outer capture.
      class RactorIsolation < Base
        explain :outer_capture,
          severity: :error,
          message: "Ractor.new block captures outer local " \
                   "variable(s) %{names}",
          why: "Block isolation is checked when Ractor.new " \
               "runs: touching locals of the enclosing scope " \
               "raises ArgumentError (\"can not isolate a " \
               "Proc because it accesses outer variables\").",
          fix: "Pass the values in as arguments, " \
               "Ractor.new(x) { |x| ... }, or send them " \
               "through a Ractor::Port."

        def visit_call_node(node)
          examine(node)
          super
        end

        private

        def examine(node)
          return unless node.name == :new
          return unless ractor_receiver?(node.receiver)

          block = node.block
          return unless block.is_a?(Prism::BlockNode)
          return unless block.body

          names = CaptureScanner.scan(block.body)
          return if names.empty?

          flag(node, :outer_capture, names: names.join(", "))
        end

        def ractor_receiver?(receiver)
          receiver.is_a?(Prism::ConstantReadNode) &&
            receiver.name == :Ractor
        end

        # Walks the Ractor block's body tracking how many block
        # scopes deep we are; a local reference with depth greater
        # than that resolves outside the Ractor block.
        class CaptureScanner < Prism::Visitor
          def self.scan(body)
            scanner = new
            scanner.visit(body)
            scanner.names.uniq
          end

          attr_reader :names

          def initialize
            @names = []
            @level = 0
            super
          end

          def visit_block_node(node)
            @level += 1
            super
          ensure
            @level -= 1
          end

          def visit_lambda_node(node)
            @level += 1
            super
          ensure
            @level -= 1
          end

          # Method definitions open fresh scopes; nothing inside
          # them can capture the surrounding locals.
          # A def opens a fresh scope, but its receiver
          # expression (`def x.foo`) evaluates in the enclosing
          # one and can capture an outer local.
          def visit_def_node(node)
            visit(node.receiver) if node.receiver
          end

          %i[
            visit_local_variable_read_node
            visit_local_variable_write_node
            visit_local_variable_operator_write_node
            visit_local_variable_or_write_node
            visit_local_variable_and_write_node
            visit_local_variable_target_node
          ].each do |method|
            define_method(method) do |node| # audition:disable unsafe-calls
              @names << node.name.to_s if node.depth > @level
              super(node)
            end
          end
        end
      end
    end
  end
end
