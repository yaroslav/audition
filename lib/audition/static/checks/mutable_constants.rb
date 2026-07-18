# frozen_string_literal: true

module Audition
  module Static
    module Checks
      # Reading a constant whose value is not *deeply* shareable from
      # a non-main Ractor raises Ractor::IsolationError.
      # Classification is deliberately conservative: values we cannot
      # prove mutable statically (method calls, constant refs,
      # splats) are left to the dynamic probe.
      class MutableConstants < Base
        CONSTANT_WHY =
          "Reading a constant that holds a non-shareable object " \
          "from a non-main Ractor raises Ractor::IsolationError " \
          "(\"can not access non-shareable objects in constant\")."

        explain :mutable_string,
          severity: :error,
          message: "constant %{name} holds an unfrozen " \
                   "String literal",
          why: CONSTANT_WHY,
          fix: "Add `# frozen_string_literal: true` to the " \
               "file, or append `.freeze`."

        explain :mutable_container,
          severity: :error,
          message: "constant %{name} holds a mutable %{type} " \
                   "literal",
          why: CONSTANT_WHY,
          fix: "Make it deeply shareable: " \
               "`# shareable_constant_value: literal`, or " \
               "wrap in Ractor.make_shareable(...). A bare " \
               "`.freeze` is not enough when elements are " \
               "themselves mutable."

        explain :shallow_freeze,
          severity: :error,
          message: "constant %{name} is frozen only at the " \
                   "top level",
          why: "Ractor shareability is deep: the outer " \
               "object is frozen but its elements are not, " \
               "so a non-main Ractor still raises " \
               "Ractor::IsolationError reading it (verified: " \
               "[[1], [2]].freeze raises).",
          fix: "Use Ractor.make_shareable(...) for a deep " \
               "freeze, or `# shareable_constant_value: " \
               "literal`."

        explain :sync_primitive,
          severity: :error,
          message: "constant %{name} holds a %{klass}; sync " \
                   "primitives are deliberately unshareable",
          why: "Mutex/Queue/ConditionVariable coordinate " \
               "threads inside one Ractor and can never be " \
               "shared across Ractors; any non-main Ractor " \
               "touching this constant raises " \
               "Ractor::IsolationError.",
          fix: "Use Ractor::Port for cross-Ractor " \
               "coordination, keep a per-Ractor primitive " \
               "via Ractor.store_if_absent, or use " \
               "Ractor-safe structures (ractor_safe, ratomic " \
               "gems)."

        explain :proc_constant,
          severity: :error,
          message: "constant %{name} holds a Proc",
          why: "Procs capture their creation environment and " \
               "are not shareable; a non-main Ractor reading " \
               "this constant raises Ractor::IsolationError.",
          fix: "Wrap in Ractor.make_shareable(->(...) { ... }); " \
               "it isolates self-contained lambdas; or " \
               "promote the logic to a method."

        explain :hash_default_proc,
          severity: :error,
          message: "constant %{name} holds a Hash with a " \
                   "default proc",
          why: "The default block is a Proc baked into the " \
               "Hash, and freezing the Hash does not make " \
               "the block shareable; a non-main Ractor " \
               "reading this constant raises " \
               "Ractor::IsolationError. Rails removed this " \
               "pattern twice during its ractorization.",
          fix: "Use a plain frozen Hash with explicit keys, " \
               "or drop the default proc and fetch with a " \
               "literal default: hash.fetch(key, [])."

        explain :constant_mutation,
          severity: :warning,
          message: "in-place %{method} on constant %{name}",
          why: "A constant mutated after load is shared " \
               "mutable state: non-main Ractors raise " \
               "Ractor::IsolationError reading it while " \
               "unfrozen, and freezing it turns this call " \
               "into a FrozenError.",
          fix: "Build the complete value at load time and " \
               "freeze it (each_with_object then .freeze), " \
               "or move the registry behind a writer that " \
               "rebuilds and refreezes on each change, the " \
               "copy-on-write style Rails registries use."

        on :constant_write_node, :constant_or_write_node do |node|
          examine(node.name.to_s, node, node.value)
        end

        on :call_node do |node|
          flag_constant_mutation(node)
        end

        on :constant_path_write_node,
          :constant_path_or_write_node do |node|
          examine(node.target.location.slice, node, node.value)
        end

        private

        def examine(name, node, value)
          return if file.shareable_constants?

          case classifier.classify(value)
          when :mutable_string
            flag(node, :mutable_string, name: name,
              autofix: append_freeze(value))
          when :mutable_container
            flag(node, :mutable_container, name: name,
              type: container_type(value),
              autofix: wrap_make_shareable(value))
          when :shallow_freeze
            flag(node, :shallow_freeze, name: name,
              autofix: replace_with_make_shareable(value))
          when :sync_primitive
            flag(node, :sync_primitive, name: name,
              klass: classifier.const_name(value.receiver))
          when :proc
            flag(node, :proc_constant, name: name,
              autofix: wrap_make_shareable(value))
          when :default_proc
            flag(node, :hash_default_proc, name: name)
          end
        end

        # Mutators that read as data mutation, not as class-level
        # method names (delete/update/store would collide with
        # Active Record class methods). Screaming-case receivers
        # only: `RENDERERS << x` is a registry mutation, while
        # `User << x` is a class method call.
        MUTATORS = Ractor.make_shareable(
          %i[[]= << push unshift concat merge! replace]
        )

        def flag_constant_mutation(node)
          return unless MUTATORS.include?(node.name)

          name = classifier.const_name(node.receiver)
          return unless name
          return if name == "ENV"
          return unless name.split("::").last
            .match?(/\A[A-Z][A-Z0-9_]*\z/)

          flag(node, :constant_mutation, name: name,
            method: node.name.to_s)
        end

        def container_type(value)
          case value
          when Prism::HashNode, Prism::KeywordHashNode then "Hash"
          when Prism::ArrayNode then "Array"
          when Prism::CallNode
            classifier.const_name(value.receiver) || "container"
          else
            "container"
          end
        end

        def classifier
          @classifier ||= LiteralClassifier.new(
            frozen_string_literal: file.frozen_string_literal?
          )
        end

        def append_freeze(value)
          offset = value.location.end_offset
          Autofix.new(
            start_offset: offset,
            end_offset: offset,
            replacement: ".freeze"
          )
        end

        def wrap_make_shareable(value)
          source = value.location.slice
          Autofix.new(
            start_offset: value.location.start_offset,
            end_offset: value.location.end_offset,
            replacement: "Ractor.make_shareable(#{source})"
          )
        end

        # Replaces the whole `<literal>.freeze` call with a deep
        # wrap of the literal.
        def replace_with_make_shareable(call)
          source = call.receiver.location.slice
          Autofix.new(
            start_offset: call.location.start_offset,
            end_offset: call.location.end_offset,
            replacement: "Ractor.make_shareable(#{source})"
          )
        end
      end
    end
  end
end
