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
      # non-literal constant values (verified on 4.0), so it is only
      # planned when every constant assignment in the file
      # classifies as a literal. Otherwise, if the flagged values
      # are all strings, frozen_string_literal covers them.
      def self.plan(file, findings)
        return nil if file.shareable_constants?
        return nil if findings.none? { |f| f.check == "mutable-constants" }

        classifier = Static::LiteralClassifier.new(
          frozen_string_literal: file.frozen_string_literal?
        )
        kinds = constant_values(file).map { |v| classifier.classify(v) }
        flagged = kinds.reject do |k|
          %i[shareable unknown].include?(k)
        end
        scv_ok = kinds.all? do |k|
          %i[shareable mutable_string mutable_container
            shallow_freeze].include?(k)
        end

        if scv_ok
          comment_plan(file, SCV_LINE)
        elsif !file.frozen_string_literal? &&
            flagged.all? { |k| k == :mutable_string }
          comment_plan(file, FSL_LINE)
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
          define_method(method) do |node|
            @values << node.value
            super(node)
          end
        end
      end
    end

    # -- class-level memoization -------------------------------------

    # Rewrites singleton-scope ivar state to Ractor-local storage:
    #   @x ||= expr   ->  Ractor.store_if_absent(:"Klass/@x") { expr }
    #   @x = expr     ->  Ractor.current[:"Klass/@x"] = expr
    #   @x            ->  Ractor.current[:"Klass/@x"]
    # Only when every reference in singleton scope is visible in
    # this file, none sit directly in the class body, and no
    # compound writes exist. Caveat (why this is unsafe): each
    # Ractor computes its own copy, and store_if_absent treats a
    # stored nil as present where ||= would recompute.
    module Memoization
      def self.plan(file, findings)
        return [] if findings.none? { |f| f.check == "class-level-state" }

        collector = SingletonIvars.new
        collector.visit(file.root)
        edits = []
        collector.groups.each do |(namespace, name), ops|
          next if namespace.empty?

          kinds = ops.map { |op| op[:kind] }
          next unless kinds.include?(:or_write)
          next if kinds.include?(:other)
          next if ops.any? { |op| op[:body] }

          key = %(:"#{namespace}/#{name}")
          ops.each { |op| edits << edit_for(op, key) }
        end
        edits
      end

      def self.edit_for(op, key)
        node = op[:node]
        case op[:kind]
        when :or_write
          value = node.value.location.slice
          Autofix.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement:
              "Ractor.store_if_absent(#{key}) { #{value} }",
            safety: :unsafe
          )
        when :write
          Autofix.new(
            start_offset: node.name_loc.start_offset,
            end_offset: node.name_loc.end_offset,
            replacement: "Ractor.current[#{key}]",
            safety: :unsafe
          )
        when :read
          Autofix.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement: "Ractor.current[#{key}]",
            safety: :unsafe
          )
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
          @def_stack.push(kind)
          super
        ensure
          @def_stack.pop
        end

        {
          visit_instance_variable_read_node: :read,
          visit_instance_variable_write_node: :write,
          visit_instance_variable_or_write_node: :or_write,
          visit_instance_variable_operator_write_node: :other,
          visit_instance_variable_and_write_node: :other,
          visit_instance_variable_target_node: :other
        }.each do |method, kind|
          define_method(method) do |node|
            record(node, kind)
            super(node)
          end
        end

        private

        def record(node, kind)
          return if @namespace.empty?

          in_def = !@def_stack.empty?
          singleton_method =
            @def_stack.last == :self ||
            (@def_stack.last == :plain && @sclass_depth.positive?)
          if in_def
            return unless singleton_method

            body = false
          else
            body = true
          end

          key = [@namespace.join("::"), node.name.to_s]
          @groups[key] << {node: node, kind: kind, body: body}
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
          define_method(method) do |node|
            record_gvar(node, kind) if @mode == :gvar
            super(node)
          end
        end

        CVAR_NODES.each do |method, kind|
          define_method(method) do |node|
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
