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
      #
      # Ractor.shareable_proc applies a weaker rule to any block at
      # conversion time: a captured local may not hold an
      # unshareable object and may not be assigned more than once.
      # Rails converts the blocks handed to its callback macros the
      # same way once unshareable_proc_action is set, so a callback
      # whose capture is provably unshareable is reported too; a
      # capture of unknown value stays silent, and the boot gate is
      # its detector.
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

        CAPTURE_FIX =
          "Capture a shareable value: freeze the local (a " \
          "frozen literal or .freeze), inline it, or hoist a " \
          "shareable leaf such as a Symbol into a fresh local " \
          "assigned once before the block."

        explain :shareable_proc_capture,
          severity: :error,
          message: "%{method} block captures %{what}",
          why: "Ractor.shareable_proc refuses a block that can " \
               "refer to an unshareable object through an outer " \
               "local, or whose outer local is assigned more " \
               "than once, with Ractor::IsolationError at " \
               "conversion time.",
          fix: CAPTURE_FIX

        explain :callback_capture,
          severity: :warning,
          message: "block passed to %{method} captures %{what}",
          why: "Rails stores the block as a callback and, with " \
               "unshareable_proc_action set to :warn or :raise, " \
               "runs it through Ractor.shareable_proc; a block " \
               "that refers to an unshareable local, or to one " \
               "assigned more than once, cannot be made " \
               "shareable and stays an unshareable Proc, which " \
               "raises Ractor::IsolationError once a non-main " \
               "Ractor runs the callback.",
          fix: CAPTURE_FIX

        # Methods that keep their block for later, as a callback or
        # boot hook; Rails runs each through try_shareable_proc.
        CALLBACK_MACROS = %i[
          validate validates_each set_callback on_load initializer
          to_prepare rescue_from scope default_scope
        ].freeze
        CALLBACK_PREFIXES = %w[
          before_ after_ around_ prepend_before_ prepend_after_
          prepend_around_ append_before_ append_after_
          append_around_
        ].freeze
        CONVERTERS = %i[shareable_proc shareable_lambda].freeze

        # Classifications a captured value must have for the
        # conversion to fail for certain.
        UNSHAREABLE_KINDS = %i[
          mutable_string mutable_container mutable_call
          sync_primitive default_proc proc
        ].freeze

        def initialize(file)
          super
          @frames = []
          @pending = []
        end

        # Captures are judged once the whole file is read: a local
        # reassigned after the block is refused just the same.
        def visit_program_node(node)
          framed { super }
          @pending.each { |entry| judge(entry) }
        end

        def visit_class_node(node) = framed { super }

        def visit_module_node(node) = framed { super }

        def visit_singleton_class_node(node) = framed { super }

        def visit_def_node(node) = framed { super }

        def visit_block_node(node) = framed { super }

        def visit_lambda_node(node) = framed { super }

        def visit_local_variable_write_node(node)
          assign(node.name, node.depth, node.value)
          super
        end

        def visit_local_variable_or_write_node(node)
          assign(node.name, node.depth, nil)
          super
        end

        def visit_local_variable_operator_write_node(node)
          assign(node.name, node.depth, nil)
          super
        end

        def visit_local_variable_and_write_node(node)
          assign(node.name, node.depth, nil)
          super
        end

        def visit_local_variable_target_node(node)
          assign(node.name, node.depth, nil)
          super
        end

        def visit_call_node(node)
          examine(node)
          super
        end

        private

        def framed
          @frames.push({})
          yield
        ensure
          @frames.pop
        end

        # Prism resolves a local write to the scope `depth` levels
        # up; the frame at that level records every assignment so
        # the capture judge can count them and classify the value.
        def assign(name, depth, value)
          frame = @frames[-1 - depth]
          return unless frame

          (frame[name.to_s] ||= []) << value
        end

        def examine(node)
          block = node.block
          return unless block.is_a?(Prism::BlockNode) && block.body

          if node.name == :new && ractor_receiver?(node.receiver)
            names = CaptureScanner.scan(block.body)
            return if names.empty?

            flag(node, :outer_capture, names: names.join(", "))
          elsif CONVERTERS.include?(node.name)
            defer(node, :shareable_proc_capture)
          elsif callback_macro?(node.name)
            defer(node, :callback_capture)
          end
        end

        def ractor_receiver?(receiver)
          receiver.is_a?(Prism::ConstantReadNode) &&
            receiver.name == :Ractor
        end

        def callback_macro?(name)
          return true if CALLBACK_MACROS.include?(name)

          text = name.to_s
          CALLBACK_PREFIXES.any? { |prefix| text.start_with?(prefix) }
        end

        # The frames a capture resolves to are the ones open now;
        # they keep filling as traversal continues, so the entry
        # holds references and is judged at the end.
        def defer(node, key)
          captures = CaptureScanner.captures(node.block.body)
          return if captures.empty?

          resolved = captures.filter_map do |name, depth|
            frame = @frames[-depth]
            [name, frame] if frame
          end
          return if resolved.empty?

          @pending << {node: node, key: key, captures: resolved}
        end

        def judge(entry)
          what = entry[:captures].filter_map do |name, frame|
            describe_capture(name, frame[name])
          end
          return if what.empty?

          node = entry[:node]
          flag(node, entry[:key],
            method: method_display(node), what: what.join(", "))
        end

        def describe_capture(name, assignments)
          return nil if assignments.nil? || assignments.empty?
          return "reassigned local #{name}" if assignments.size > 1

          value = assignments.first
          return nil if value.nil?

          if UNSHAREABLE_KINDS.include?(classifier.classify(value))
            "unshareable local #{name}"
          end
        end

        def method_display(node)
          receiver = node.receiver
          case receiver
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            "#{receiver.location.slice}.#{node.name}"
          else
            node.name.to_s
          end
        end

        def classifier
          @classifier ||= LiteralClassifier.new(
            frozen_string_literal: file.frozen_string_literal?
          )
        end

        # Walks a block's body tracking how many block scopes deep
        # we are; a local reference with depth greater than that
        # resolves outside the block, `depth - level` scopes above
        # it.
        class CaptureScanner < Prism::Visitor
          def self.scan(body)
            captures(body).map(&:first)
          end

          # @return [Array<Array(String, Integer)>] each captured
          #   name once, with how many scopes above the block it
          #   lives
          def self.captures(body)
            scanner = new
            scanner.visit(body)
            scanner.captures.uniq(&:first)
          end

          attr_reader :captures

          def initialize
            @captures = []
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

          # Plain defs, not a define_method loop: the parallel
          # scan calls these from worker Ractors, and a method
          # born from define_method carries an un-shareable Proc
          # that raises when dispatched from another Ractor.
          def visit_local_variable_read_node(node)
            note(node)
            super
          end

          def visit_local_variable_write_node(node)
            note(node)
            super
          end

          def visit_local_variable_operator_write_node(node)
            note(node)
            super
          end

          def visit_local_variable_or_write_node(node)
            note(node)
            super
          end

          def visit_local_variable_and_write_node(node)
            note(node)
            super
          end

          def visit_local_variable_target_node(node)
            note(node)
            super
          end

          private

          def note(node)
            return unless node.depth > @level

            @captures << [node.name.to_s, node.depth - @level]
          end
        end
      end
    end
  end
end
