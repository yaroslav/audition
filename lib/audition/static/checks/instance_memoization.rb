# frozen_string_literal: true

module Audition
  module Static
    module Checks
      # Lazy memoization on an instance is harmless until the
      # instance is frozen: Ractor.make_shareable freezes every
      # object it reaches, and the next `@x ||=` raises FrozenError.
      # Two shapes make the freeze provable from the class alone: an
      # initialize that ends by freezing self (a value object), and a
      # `freeze` override (the class expects to be frozen). In the
      # first the memo can never run; in the second it must be
      # warmed inside the override, before super, which is the
      # compute-on-freeze pattern. Class-level memos belong to the
      # graph audit.
      class InstanceMemoization < Base
        explain :memo_after_self_freeze,
          severity: :error,
          message: "instance memoization %{ivar} in #%{method} on " \
                   "a class that freezes itself in initialize",
          why: "The instance is frozen before any other method " \
               "runs, so the first call writes an instance " \
               "variable on a frozen object and raises " \
               "FrozenError.",
          fix: "Compute the value in initialize, before the " \
               "freeze, and expose it with attr_reader; or drop " \
               "the memo and recompute on each call."

        explain :memo_not_warmed,
          severity: :warning,
          message: "freeze override leaves %{ivar} cold; " \
                   "#%{method} memoizes it lazily",
          why: "Ractor.make_shareable calls freeze, so an " \
               "instance frozen through this override raises " \
               "FrozenError the first time #%{method} runs " \
               "afterwards.",
          fix: "Warm it in the override: call #%{method} (or " \
               "assign %{ivar}) before super, the " \
               "compute-on-freeze pattern; or compute it in " \
               "initialize."

        def initialize(file)
          super
          @contexts = []
          @sclass_depth = 0
        end

        def visit_class_node(node) = scoped { super }

        def visit_module_node(node) = scoped { super }

        def visit_singleton_class_node(node)
          @sclass_depth += 1
          super
        ensure
          @sclass_depth -= 1
        end

        # Only plain instance methods count; a def is not entered,
        # so nothing inside a method body opens a context.
        def visit_def_node(node)
          context = @contexts.last
          return unless context && node.receiver.nil? &&
            @sclass_depth.zero?

          record_method(context, node)
        end

        private

        def scoped
          @contexts.push(
            {memos: {}, methods: {}, self_freeze: false, warm: nil}
          )
          saved = @sclass_depth
          @sclass_depth = 0
          yield
        ensure
          @sclass_depth = saved
          report(@contexts.pop)
        end

        def record_method(context, node)
          case node.name
          when :initialize
            context[:self_freeze] = self_freezing?(node)
          when :freeze
            context[:warm] = touched_by(node)
          else
            context[:methods][node.name] ||= touched_by(node)
            memo_sites(node).each do |ivar, write|
              context[:memos][ivar] ||= {method: node.name, node: write}
            end
          end
        end

        def report(context)
          memos = context[:memos]
          return if memos.empty?

          if context[:self_freeze]
            memos.each do |ivar, memo|
              flag(memo[:node], :memo_after_self_freeze,
                ivar: ivar, method: memo[:method])
            end
          elsif context[:warm]
            reached, warmed = warmed_closure(context)
            memos.each do |ivar, memo|
              next if reached.include?(memo[:method]) ||
                warmed.include?(ivar)

              flag(memo[:node], :memo_not_warmed,
                ivar: ivar, method: memo[:method])
            end
          end
        end

        # Everything the override reaches through the class's own
        # instance methods: a memo is warm when its method runs on
        # the way, or when any method on the way assigns its ivar.
        def warmed_closure(context)
          methods = context[:methods]
          reached = []
          warmed = context[:warm][:ivars].dup
          queue = context[:warm][:calls].dup
          until queue.empty?
            name = queue.shift
            next if reached.include?(name)

            reached << name
            touched = methods[name] or next

            warmed.concat(touched[:ivars])
            queue.concat(touched[:calls])
          end
          [reached, warmed]
        end

        # initialize ends with `freeze`, `self.freeze`, or
        # `Ractor.make_shareable(self)`.
        def self_freezing?(node)
          last = statements_of(node.body)&.last
          return false unless last.is_a?(Prism::CallNode)

          receiver = last.receiver
          if last.name == :freeze
            (receiver.nil? || receiver.is_a?(Prism::SelfNode)) &&
              last.arguments.nil?
          elsif last.name == :make_shareable
            last.arguments&.arguments&.first.is_a?(Prism::SelfNode)
          else
            false
          end
        end

        def statements_of(body)
          case body
          when Prism::StatementsNode then body.body
          when Prism::BeginNode then body.statements&.body
          end
        end

        # The methods a body calls on self and the ivars it assigns.
        def touched_by(node)
          calls = []
          ivars = []
          each_descendant(node.body) do |child|
            case child
            when Prism::CallNode
              receiver = child.receiver
              if receiver.nil? || receiver.is_a?(Prism::SelfNode)
                calls << child.name
              end
            when Prism::InstanceVariableWriteNode,
                 Prism::InstanceVariableOrWriteNode
              ivars << child.name.to_s
            end
          end
          {calls: calls, ivars: ivars}
        end

        # `@x ||= v`, and `@x = v` guarded by `defined?(@x)` in the
        # same method.
        def memo_sites(node)
          or_writes = []
          writes = {}
          guarded = []
          each_descendant(node.body) do |child|
            case child
            when Prism::InstanceVariableOrWriteNode
              or_writes << [child.name.to_s, child]
            when Prism::InstanceVariableWriteNode
              writes[child.name.to_s] ||= child
            when Prism::DefinedNode
              value = child.value
              if value.is_a?(Prism::InstanceVariableReadNode)
                guarded << value.name.to_s
              end
            end
          end
          guarded.each do |ivar|
            or_writes << [ivar, writes[ivar]] if writes[ivar]
          end
          or_writes
        end

        # Blocks and lambdas inside a method still write self's
        # ivars; a nested def or class does not.
        def each_descendant(node)
          queue = [node].compact
          until queue.empty?
            current = queue.shift
            yield current
            current.compact_child_nodes.each do |child|
              next if child.is_a?(Prism::DefNode) ||
                child.is_a?(Prism::ClassNode) ||
                child.is_a?(Prism::ModuleNode)

              queue << child
            end
          end
        end
      end
    end
  end
end
