# frozen_string_literal: true

require "prism"

module Audition
  # Unsafe-tier, multi-site rewrites planned at fix time from a
  # parsed file plus its findings. Each .plan returns Autofix edits
  # (safety :unsafe) or, for MagicComments, a file-level edit plus
  # the list of checks it makes redundant.
  module Rewriters
    # -- magic comments ----------------------------------------------

    module MagicComments
      SCV_LINE = "# shareable_constant_value: literal\n"
      FSL_LINE = "# frozen_string_literal: true\n"

      # `shareable_constant_value: literal` raises at load for
      # non-literal constant values (verified on 4.0), so it is
      # only planned when every constant assignment in the file is
      # a literal all the way down: an array literal holding a
      # local or a call (Racc-generated parser tables are the
      # canonical case) becomes an unshareable value that the
      # magic comment rejects at load time. Otherwise, if the
      # flagged values are all strings, frozen_string_literal
      # covers them.
      def self.plan(file, findings)
        return nil if file.shareable_constants?
        return nil if findings.none? { |f| f.check == "mutable-constants" }

        classifier = Static::LiteralClassifier.new(
          frozen_string_literal: file.frozen_string_literal?
        )
        values = constant_values(file)
        kinds = values.map { |v| classifier.classify(v) }
        flagged = kinds.reject do |k|
          %i[shareable unknown].include?(k)
        end
        scv_ok = values.all? do |value|
          deep_literal?(value, classifier)
        end

        if scv_ok
          comment_plan(file, SCV_LINE)
        elsif !file.frozen_string_literal? &&
            flagged.all? { |k| k == :mutable_string }
          comment_plan(file, FSL_LINE)
        end
      end

      def self.deep_literal?(node, classifier)
        case node
        when Prism::ArrayNode
          node.elements.all? do |element|
            deep_literal?(element, classifier)
          end
        when Prism::HashNode, Prism::KeywordHashNode
          node.elements.all? do |element|
            element.is_a?(Prism::AssocNode) &&
              deep_literal?(element.key, classifier) &&
              deep_literal?(element.value, classifier)
          end
        when Prism::CallNode
          node.name == :freeze && node.arguments.nil? &&
            node.receiver &&
            deep_literal?(node.receiver, classifier)
        else
          %i[shareable mutable_string]
            .include?(classifier.classify(node))
        end
      end

      def self.comment_plan(file, line)
        offset = file.magic_insertion_offset
        {
          edit: Autofix.new(start_offset: offset,
            end_offset: offset,
            replacement: line,
            safety: :unsafe),
          covers: ["mutable-constants"]
        }
      end

      def self.constant_values(file)
        collector = ConstantValues.new
        collector.visit(file.root)
        collector.values
      end

      class ConstantValues < Prism::Visitor
        attr_reader :values

        def initialize
          @values = []
          super
        end

        %i[
          visit_constant_write_node
          visit_constant_or_write_node
          visit_constant_path_write_node
          visit_constant_path_or_write_node
        ].each do |method|
          define_method(method) do |node| # audition:disable unsafe-calls
            @values << node.value
            super(node)
          end
        end
      end
    end

    # -- class-level memoization -------------------------------------

    # Rewrites singleton-scope memoization, both idioms:
    #   @x ||= expr
    #   return @x if defined?(@x); @x = expr
    #
    # Preferred strategy is freeze-on-memoize, the pattern Rails
    # core applies to its own code: the memoization stays exactly
    # as written and only the memoized value becomes shareable
    # (`.freeze` appended; Ractor.make_shareable for containers).
    # Non-main Ractors may then read the ivar once it has been
    # computed; the first write must still happen on the main
    # Ractor, which is a boot-warming concern the static check
    # reports as an info note. Chosen when the value expression
    # carries no block (a proxy for one-time side effects) and no
    # writes exist outside the memo sites.
    #
    # Otherwise falls back to Ractor-local storage:
    #   @x ||= expr   ->  Ractor.store_if_absent(:"Klass/@x") { expr }
    #   @x = expr     ->  Ractor.current[:"Klass/@x"] = expr
    #   @x            ->  Ractor.current[:"Klass/@x"]
    #
    # Only when every reference in singleton scope is visible in
    # this file, none sit directly in the class body, and no
    # compound writes exist. Caveat (why this is unsafe): freezing
    # changes value mutability, and each Ractor computes its own
    # copy under store_if_absent.
    module Memoization
      def self.plan(file, findings)
        return [] if findings.none? { |f| f.check == "class-level-state" }

        collector = SingletonIvars.new
        collector.visit(file.root)
        edits = []
        collector.groups.each do |(namespace, name), ops|
          next if namespace.empty?

          kinds = ops.map { |op| op[:kind] }
          next if kinds.include?(:other)
          next if ops.any? { |op| op[:body] }

          memos = memo_sites(ops)
          next if memos.empty?
          next if orphan_guards?(ops, memos)
          next if guarded_with_strays?(ops, memos)

          if freezable?(ops, memos)
            edits.concat(freeze_edits(file, memos))
          else
            key = %(:"#{namespace}/#{name}")
            edits.concat(ractor_edits(file, ops, memos, key))
          end
        end
        edits
      end

      # A memo site is an ||= write, or a plain write paired with a
      # defined? return guard inside the same method. A guarded
      # method with more than one write is nobody's memoization;
      # such groups are dropped by the orphan check below.
      def self.memo_sites(ops)
        guards = ops.select { |op| op[:kind] == :guard }
        ops.filter_map do |op|
          case op[:kind]
          when :or_write
            {op: op, guard: nil}
          when :write
            guard = guards.find { |g| g[:def_id] == op[:def_id] }
            {op: op, guard: guard} if guard
          end
        end
      end

      def self.guarded_with_strays?(ops, memos)
        return false if memos.none? { |memo| memo[:guard] }

        memo_ops = memos.map { |memo| memo[:op] }
        ops.any? do |op|
          op[:kind] == :write && !memo_ops.include?(op)
        end
      end

      def self.orphan_guards?(ops, memos)
        used = memos.filter_map { |m| m[:guard] }
        guards = ops.select { |op| op[:kind] == :guard }
        return true if guards.size != used.size

        writes = ops.select { |op| op[:kind] == :write }
        guards.any? do |guard|
          writes.count { |w| w[:def_id] == guard[:def_id] } != 1
        end
      end

      # Freeze-on-memoize applies when every write is a memo site
      # (a stray write means cache invalidation; frozen values
      # cannot support that) and no value needs a block to build.
      def self.freezable?(ops, memos)
        memo_ops = memos.map { |memo| memo[:op] }
        writes = ops.select { |op| op[:kind] == :write }
        return false unless (writes - memo_ops).empty?

        memos.all? { |memo| blockless?(memo[:op][:node].value) }
      end

      def self.blockless?(node)
        queue = [node]
        until queue.empty?
          current = queue.shift
          if current.is_a?(Prism::BlockNode) ||
              current.is_a?(Prism::LambdaNode)
            return false
          end
          queue.concat(current.child_nodes.compact)
        end
        true
      end

      # One edit per memo site: make the memoized value shareable
      # while leaving the memoization intact. Guards, sibling
      # reads, and method shapes stay untouched.
      def self.freeze_edits(file, memos)
        classifier = Static::LiteralClassifier.new(
          frozen_string_literal: file.frozen_string_literal?
        )
        memos.filter_map do |memo|
          value = memo[:op][:node].value
          freeze_value(value, classifier.classify(value))
        end
      end

      def self.freeze_value(value, kind)
        return nil if kind == :shareable
        return nil if frozen_call?(value)

        slice = value.location.slice
        replacement =
          case kind
          when :mutable_container, :shallow_freeze
            "Ractor.make_shareable(#{slice})"
          else
            parens?(value) ? "(#{slice}).freeze" : "#{slice}.freeze"
          end
        Autofix.new(
          start_offset: value.location.start_offset,
          end_offset: value.location.end_offset,
          replacement: replacement,
          safety: :unsafe
        )
      end

      def self.frozen_call?(value)
        value.is_a?(Prism::CallNode) &&
          value.name == :freeze &&
          value.receiver && value.arguments.nil?
      end

      # `.freeze` binds tighter than operators and ternaries, so
      # compound expressions get wrapped; message sends and plain
      # literals do not need it.
      def self.parens?(value)
        case value
        when Prism::CallNode
          !value.name.to_s.match?(/\A[a-z_]/i)
        when Prism::StringNode, Prism::InterpolatedStringNode,
             Prism::ArrayNode, Prism::HashNode,
             Prism::ConstantReadNode, Prism::ConstantPathNode
          false
        else
          true
        end
      end

      # Two Ractor-local flavors. With stray writes present (cache
      # invalidation, `@x = nil`), memo sites become
      # `Ractor.current[key] ||= expr`: it recomputes after a nil
      # reset exactly like the original `||=`, where
      # store_if_absent would treat the stored nil as present and
      # never recompute (this broke i18n's reserved_keys_pattern).
      # Without strays, store_if_absent keeps its atomic lazy
      # init. Guard-idiom groups with strays are skipped entirely
      # in plan: the defined? guard caches nil deliberately and
      # neither flavor reproduces that alongside invalidation.
      def self.ractor_edits(file, ops, memos, key)
        guarded = memos.filter_map { |m| m[:op] if m[:guard] }
        memo_ops = memos.map { |memo| memo[:op] }
        strays = ops.any? do |op|
          op[:kind] == :write && !memo_ops.include?(op)
        end
        edits = memos.filter_map do |memo|
          deletion(file.source, memo[:guard][:node]) if memo[:guard]
        end
        ops.each do |op|
          node = op[:node]
          edits <<
            if op[:kind] == :or_write || guarded.include?(op)
              replacement =
                if strays
                  value = node.value.location.slice
                  "Ractor.current[#{key}] ||= #{value}"
                else
                  store_wrap(file.source, node, key)
                end
              Autofix.new(
                start_offset: node.location.start_offset,
                end_offset: node.location.end_offset,
                replacement: replacement,
                safety: :unsafe
              )
            elsif op[:kind] == :write
              Autofix.new(
                start_offset: node.name_loc.start_offset,
                end_offset: node.name_loc.end_offset,
                replacement: "Ractor.current[#{key}]",
                safety: :unsafe
              )
            else
              Autofix.new(
                start_offset: node.location.start_offset,
                end_offset: node.location.end_offset,
                replacement: "Ractor.current[#{key}]",
                safety: :unsafe
              )
            end
        end
        edits
      end

      # A single-line value keeps the brace form; a multi-line
      # value becomes a do..end block with the body shifted one
      # level right, so the rewrite stays idiomatic. When the write
      # shares its line with other code, layout cannot be inferred
      # and the brace form is kept as-is.
      def self.store_wrap(source, node, key)
        value = node.value.location.slice
        call = "Ractor.store_if_absent(#{key})"
        return "#{call} { #{value} }" unless value.include?("\n")

        from = node.location.start_offset
        start = from.zero? ? 0 : (source.rindex("\n", from - 1) || -1) + 1
        indent = source[start...from]
        return "#{call} { #{value} }" unless indent.match?(/\A[ \t]*\z/)

        body = value.lines.map.with_index do |line, index|
          if index.zero?
            "#{indent}  #{line}"
          elsif line.match?(/\A\s*\z/)
            line
          else
            "  #{line}"
          end
        end.join
        "#{call} do\n#{body}\n#{indent}end"
      end

      # Deletes the guard statement together with its line and any
      # blank lines that follow, so the method body does not open
      # with a hole. Falls back to the bare node span when other
      # code shares the line.
      def self.deletion(source, node)
        from = node.location.start_offset
        upto = node.location.end_offset
        start = from.zero? ? 0 : (source.rindex("\n", from - 1) || -1) + 1
        if source[start...from].match?(/\A[ \t]*\z/)
          newline = source.index("\n", upto)
          stop = newline ? newline + 1 : source.length
          loop do
            newline = source.index("\n", stop)
            break unless newline
            break unless source[stop...newline].match?(/\A[ \t]*\z/)

            stop = newline + 1
          end
          Autofix.new(start_offset: start, end_offset: stop,
            replacement: "", safety: :unsafe)
        else
          Autofix.new(start_offset: from, end_offset: upto,
            replacement: "", safety: :unsafe)
        end
      end

      # Collects ivar operations that touch the class object:
      # inside `def self.x`, inside `class << self` methods, or
      # directly in the class body (recorded with body: true, which
      # disqualifies the group). Instance-method ivars are ignored.
      class SingletonIvars < Prism::Visitor
        attr_reader :groups

        def initialize
          @groups = Hash.new { |h, k| h[k] = [] }
          @namespace = []
          @sclass_depth = 0
          @def_stack = []
          super
        end

        def visit_class_node(node)
          @namespace.push(node.constant_path.location.slice)
          super
        ensure
          @namespace.pop
        end

        def visit_module_node(node)
          @namespace.push(node.constant_path.location.slice)
          super
        ensure
          @namespace.pop
        end

        def visit_singleton_class_node(node)
          if node.expression.is_a?(Prism::SelfNode)
            @sclass_depth += 1
            begin
              super
            ensure
              @sclass_depth -= 1
            end
          else
            super
          end
        end

        def visit_def_node(node)
          kind =
            node.receiver.is_a?(Prism::SelfNode) ? :self : :plain
          @def_stack.push(
            {kind: kind, id: node.object_id, name: node.name}
          )
          super
        ensure
          @def_stack.pop
        end

        # Matches the guard statement of the second memoization
        # idiom: `return @x if defined?(@x)`. On a match the inner
        # reads are not visited (they belong to the guard, not to
        # the data flow) and the whole statement is recorded so the
        # planner can delete it.
        def visit_if_node(node)
          name = guard_name(node)
          if name
            record(node, :guard, name)
          else
            super
          end
        end

        {
          visit_instance_variable_read_node: :read,
          visit_instance_variable_write_node: :write,
          visit_instance_variable_or_write_node: :or_write,
          visit_instance_variable_operator_write_node: :other,
          visit_instance_variable_and_write_node: :other,
          visit_instance_variable_target_node: :other
        }.each do |method, kind|
          define_method(method) do |node| # audition:disable unsafe-calls
            record(node, kind, node.name)
            super(node)
          end
        end

        private

        def guard_name(node)
          predicate = node.predicate
          return unless predicate.is_a?(Prism::DefinedNode)

          checked = predicate.value
          return unless checked.is_a?(Prism::InstanceVariableReadNode)
          return if node.subsequent

          body = node.statements&.body
          return unless body && body.size == 1
          return unless body[0].is_a?(Prism::ReturnNode)

          returned = body[0].arguments&.arguments
          return unless returned && returned.size == 1
          return unless returned[0]
            .is_a?(Prism::InstanceVariableReadNode)
          return unless returned[0].name == checked.name

          checked.name
        end

        def record(node, kind, name)
          return if @namespace.empty?

          current_def = @def_stack.last
          singleton_method =
            current_def && (
              current_def[:kind] == :self ||
              (current_def[:kind] == :plain &&
                @sclass_depth.positive?)
            )
          if current_def
            return unless singleton_method

            body = false
          else
            body = true
          end

          key = [@namespace.join("::"), name.to_s]
          @groups[key] << {
            node: node, kind: kind, body: body,
            def_id: current_def && current_def[:id],
            def_name: current_def && current_def[:name]
          }
        end
      end
    end

    # -- write-once globals and class variables ----------------------

    # A variable written exactly once, at a scope where constant
    # assignment is legal, with every other reference a plain read
    # in the same file, converts mechanically to a frozen constant.
    # Unsafe because cross-file readers are invisible.
    module WriteOnce
      def self.plan(file, findings)
        edits = []
        if findings.any? { |f| f.check == "global-variables" }
          edits += globals(file)
        end
        if findings.any? { |f| f.check == "class-variables" }
          edits += class_variables(file)
        end
        edits
      end

      def self.globals(file)
        collector = Variables.new(:gvar)
        collector.visit(file.root)
        convert(collector, file) do |name|
          name.delete_prefix("$").upcase
        end
      end

      def self.class_variables(file)
        collector = Variables.new(:cvar)
        collector.visit(file.root)
        convert(collector, file) do |name|
          name.delete_prefix("@@").upcase
        end
      end

      def self.convert(collector, file)
        classifier = Static::LiteralClassifier.new(
          frozen_string_literal: file.frozen_string_literal?
        )
        edits = []
        collector.groups.each do |name, ops|
          writes = ops.select { |op| op[:kind] == :write }
          next unless writes.size == 1 && writes[0][:assignable]
          next unless (ops - writes).all? { |op| op[:kind] == :read }

          write = writes[0][:node]
          shareable = classifier.classify(write.value) == :shareable
          # A mutable value that would get deep-frozen must never be
          # the receiver of a call afterwards: `X[k] = v`, `X << v`
          # and friends would raise FrozenError at runtime. Reads of
          # immutable values are safe anywhere.
          unless shareable
            mutated = (ops - writes).any? do |op|
              collector.receiver_reads.include?(op[:node].object_id)
            end
            next if mutated
          end

          constant = yield(name.split("/").last)
          next unless constant.match?(/\A[A-Z][A-Z0-9_]*\z/)
          next if collector.taken_constants.include?(constant)

          edits << Autofix.new(
            start_offset: write.name_loc.start_offset,
            end_offset: write.name_loc.end_offset,
            replacement: constant,
            safety: :unsafe
          )
          unless shareable
            value = write.value
            source = value.location.slice
            edits << Autofix.new(
              start_offset: value.location.start_offset,
              end_offset: value.location.end_offset,
              replacement: "Ractor.make_shareable(#{source})",
              safety: :unsafe
            )
          end
          (ops - writes).each do |op|
            node = op[:node]
            edits << Autofix.new(
              start_offset: node.location.start_offset,
              end_offset: node.location.end_offset,
              replacement: constant,
              safety: :unsafe
            )
          end
        end
        edits
      end

      # Collects either global or class variable operations.
      # Globals group process-wide; class variables group per
      # namespace so a name reused in two classes never merges.
      # `assignable` marks writes at a scope where a constant
      # assignment would be legal (no surrounding def or block).
      class Variables < Prism::Visitor
        SKIP_GLOBALS = (
          Static::Checks::GlobalVariables::SAFE_READS +
          Static::Checks::GlobalVariables::SAFE_WRITES +
          Static::Checks::GlobalVariables::LOAD_PATH_GLOBALS
        ).freeze

        attr_reader :groups, :taken_constants, :receiver_reads

        def initialize(mode)
          @mode = mode
          @groups = Hash.new { |h, k| h[k] = [] }
          @taken_constants = []
          @receiver_reads = {}
          @namespace = []
          @def_depth = 0
          @block_depth = 0
          super()
        end

        def visit_call_node(node)
          receiver = node.receiver
          if receiver.is_a?(Prism::GlobalVariableReadNode) ||
              receiver.is_a?(Prism::ClassVariableReadNode)
            @receiver_reads[receiver.object_id] = true
          end
          super
        end

        def visit_class_node(node)
          @namespace.push(node.constant_path.location.slice)
          super
        ensure
          @namespace.pop
        end

        def visit_module_node(node)
          @namespace.push(node.constant_path.location.slice)
          super
        ensure
          @namespace.pop
        end

        def visit_def_node(node)
          @def_depth += 1
          super
        ensure
          @def_depth -= 1
        end

        def visit_block_node(node)
          @block_depth += 1
          super
        ensure
          @block_depth -= 1
        end

        def visit_lambda_node(node)
          @block_depth += 1
          super
        ensure
          @block_depth -= 1
        end

        def visit_constant_write_node(node)
          @taken_constants << node.name.to_s
          super
        end

        def visit_constant_read_node(node)
          @taken_constants << node.name.to_s
          super
        end

        GVAR_NODES = {
          visit_global_variable_read_node: :read,
          visit_global_variable_write_node: :write,
          visit_global_variable_operator_write_node: :other,
          visit_global_variable_or_write_node: :other,
          visit_global_variable_and_write_node: :other,
          visit_global_variable_target_node: :other
        }.freeze
        CVAR_NODES = {
          visit_class_variable_read_node: :read,
          visit_class_variable_write_node: :write,
          visit_class_variable_operator_write_node: :other,
          visit_class_variable_or_write_node: :other,
          visit_class_variable_and_write_node: :other,
          visit_class_variable_target_node: :other
        }.freeze

        GVAR_NODES.each do |method, kind|
          define_method(method) do |node| # audition:disable unsafe-calls
            record_gvar(node, kind) if @mode == :gvar
            super(node)
          end
        end

        CVAR_NODES.each do |method, kind|
          define_method(method) do |node| # audition:disable unsafe-calls
            record_cvar(node, kind) if @mode == :cvar
            super(node)
          end
        end

        private

        def record_gvar(node, kind)
          name = node.name.to_s
          return if SKIP_GLOBALS.include?(name)

          @groups[name] << {
            node: node, kind: kind,
            assignable: @def_depth.zero? && @block_depth.zero? &&
              @namespace.empty?
          }
        end

        def record_cvar(node, kind)
          return if @namespace.empty?

          key = "#{@namespace.join("::")}/#{node.name}"
          @groups[key] << {
            node: node, kind: kind,
            assignable: @def_depth.zero? && @block_depth.zero?
          }
        end
      end
    end
  end
end
