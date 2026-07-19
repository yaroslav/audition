# frozen_string_literal: true

require "prism"

module Audition
  # Unsafe-tier, multi-site rewrites planned at fix time from a
  # parsed file plus its findings. MagicComments.plan returns a
  # file-level edit plus the list of checks it makes redundant.
  # Memoization.plan and WriteOnce.plan return one bundle per
  # converted variable group ({edits:, sites:}, safety :unsafe);
  # Rewriters.resolve flattens them to edits after dropping groups
  # whose edits would swallow another converted group's sites.
  module Rewriters
    # A planned conversion for one variable group: the group's
    # edits plus the byte spans of every recorded site, so
    # cross-group nesting is visible before edits are applied.
    # Nil when the group produced no edits.
    def self.bundle(ops, edits)
      return nil if edits.empty?

      sites = ops.map do |op|
        location = op[:node].location
        [location.start_offset, location.end_offset]
      end
      {edits: edits, sites: sites}
    end

    # The fixer keeps the first of two overlapping edits, so an
    # edit whose span contains a site of a different converted
    # group would keep that nested site's old text while the rest
    # of the other group moves (a stale read at runtime). Such
    # groups are skipped here and keep their findings.
    def self.resolve(bundles)
      bundles.flat_map do |bundle|
        clobbers = bundles.any? do |other|
          !other.equal?(bundle) && swallows?(bundle, other)
        end
        clobbers ? [] : bundle[:edits]
      end
    end

    def self.swallows?(bundle, other)
      bundle[:edits].any? do |edit|
        next false if edit.start_offset >= edit.end_offset

        other[:sites].any? do |from, upto|
          edit.start_offset <= from && upto <= edit.end_offset
        end
      end
    end

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
        collector = constant_collector(file)
        # A constant assigned here and mutated here is a
        # deliberate accumulator (sinatra's PARAMS_CONFIG);
        # freezing the file's constants would raise at the
        # mutation site.
        return nil if mutates_own_constant?(file, collector.names)

        values = collector.values
        kinds = values.map { |v| classifier.classify(v) }
        flagged = kinds.reject do |k|
          %i[shareable unknown].include?(k)
        end
        scv_ok = values.any? &&
          values.all? { |value| deep_literal?(value, classifier) }

        # Both branches demand something to fix: with no constant
        # values (a lone constant-mutation finding) or nothing
        # flagged, a comment would freeze unrelated code while
        # fixing nothing. An explicit `frozen_string_literal:
        # false` is an author opt-out and is never overridden.
        if scv_ok
          comment_plan(file, SCV_LINE)
        elsif flagged.any? &&
            file.magic_comment("frozen_string_literal").nil? &&
            flagged.all? { |k| k == :mutable_string }
          comment_plan(file, FSL_LINE)
        end
      end

      def self.mutates_own_constant?(file, assigned)
        mutated = file.mutated_constants
        assigned.any? do |name|
          bare = name.split("::").last
          mutated.any? do |m|
            m == name || m.split("::").last == bare
          end
        end
      end

      # Bare literals only: `[...].freeze` is a method call, and
      # under the magic comment Ruby raises for it at assignment
      # because the shallowly-frozen value is unshareable
      # (verified on 4.0 with jwt's NAMED_CURVES).
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
          false
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

      def self.constant_collector(file)
        collector = ConstantValues.new
        collector.visit(file.root)
        collector
      end

      class ConstantValues < Prism::Visitor
        attr_reader :values, :names

        def initialize
          @values = []
          @names = []
          super
        end

        %i[
          visit_constant_write_node
          visit_constant_or_write_node
        ].each do |method|
          define_method(method) do |node| # audition:disable unsafe-calls
            @values << node.value
            @names << node.name.to_s
            super(node)
          end
        end

        %i[
          visit_constant_path_write_node
          visit_constant_path_or_write_node
        ].each do |method|
          define_method(method) do |node| # audition:disable unsafe-calls
            @values << node.value
            @names << node.target.location.slice
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
        bundles = []
        collector.groups.each do |(namespace, name), ops|
          next if namespace.empty?

          kinds = ops.map { |op| op[:kind] }
          next if kinds.include?(:other)
          next if ops.any? { |op| op[:body] }

          memos = memo_sites(ops)
          if memos.empty?
            bundles << Rewriters.bundle(ops, setter_edits(file, ops))
            next
          end
          next if orphan_guards?(ops, memos)
          next if guarded_with_strays?(ops, memos)
          # `@x ||= {}` is a lazily-built accumulator, mutated
          # through the accessor after memoization (jwt's
          # algorithm registry). Freezing it breaks registration
          # and Ractor-local copies would leave other Ractors an
          # empty registry; the copy-on-write refactor is human
          # work, so no edit is offered. Constructor memos (`new`,
          # `Set.new`, `.dup`) are the same family: liquid's
          # filter set and money's bank singleton both broke under
          # freezing, and per-Ractor copies hide main-Ractor
          # registrations.
          next if memos.any? { |m| accumulator?(m[:op][:node].value) }
          next if memos.any? do |m|
            constructor?(m[:op][:node].value, classifier(file))
          end

          if freezable?(ops, memos)
            bundles << Rewriters.bundle(ops, freeze_edits(file, memos))
          else
            # Ractor-local slots are keyed by lexical owner; on a
            # class the ivar is per-subclass (faraday's
            # DEFAULT_OPTIONS), and one shared key would merge
            # every subclass's state. Modules cannot be
            # subclassed, so only module-owned state converts.
            next if ops.any? { |op| op[:class_owner] }
            # Deleting the defined? guard sends every call through
            # the statements after the write, so the warm path
            # only keeps returning the memo when the guarded write
            # ends its def body (or a bare read of the same ivar
            # does).
            next unless memos.all? do |m|
              m[:guard].nil? || tail_write?(m[:op])
            end

            key = %(:"#{namespace}/#{name}")
            bundles << Rewriters.bundle(
              ops, ractor_edits(file, ops, memos, key)
            )
          end
        end
        bundles.compact
      end

      def self.tail_write?(op)
        body = op[:def_node]&.body
        return false unless body.is_a?(Prism::StatementsNode)

        statements = body.body
        index = statements.index { |s| s.equal?(op[:node]) }
        return false unless index

        rest = statements[(index + 1)..]
        return true if rest.empty?

        rest.size == 1 &&
          rest[0].is_a?(Prism::InstanceVariableReadNode) &&
          rest[0].name == op[:node].name
      end

      def self.classifier(file)
        Static::LiteralClassifier.new(
          frozen_string_literal: file.frozen_string_literal?
        )
      end

      def self.constructor?(value, classifier)
        value.is_a?(Prism::CallNode) &&
          %i[new dup clone].include?(value.name) &&
          classifier.classify(value) != :shareable
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

      def self.accumulator?(value)
        (value.is_a?(Prism::ArrayNode) ||
          value.is_a?(Prism::HashNode)) && value.elements.empty?
      end

      # Config setters (`def self.backend=(value); @backend =
      # value; end`) get the Rails try_make_shareable recipe in
      # plain Ruby: shareable values are deeply frozen so reads
      # from any Ractor become legal, unshareable values keep
      # today's behavior through the rescue. Only bare local reads
      # are wrapped; computed values are left for a human.
      def self.setter_edits(file, ops)
        receivers = nil
        ops.filter_map do |op|
          next unless op[:kind] == :write
          # Only genuine setters: a plain method restoring a saved
          # local (sinatra's route conditions) and operator defs
          # ([]=) must stay untouched.
          setter = op[:def_name].to_s
          next unless setter.match?(/\A\w+=\z/)

          value = op[:node].value
          next unless value.is_a?(Prism::LocalVariableReadNode)

          # A value the file mutates in place through the reader
          # accessor (`def self.set(k, v); options[k] = v; end`)
          # or through a direct read of the ivar must never be
          # frozen: the mutation would raise FrozenError.
          receivers ||= mutator_receivers(file)
          reader = setter.delete_suffix("=").to_sym
          mutated = receivers.any? do |receiver|
            (receiver.is_a?(Prism::CallNode) &&
              receiver.name == reader) ||
              (receiver.is_a?(Prism::InstanceVariableReadNode) &&
                receiver.name == op[:node].name)
          end
          next if mutated

          local = value.name
          Autofix.new(
            start_offset: value.location.start_offset,
            end_offset: value.location.end_offset,
            replacement:
              "(Ractor.make_shareable(#{local}) rescue #{local})",
            safety: :unsafe
          )
        end
      end

      # Receivers of in-place mutator calls anywhere in the file,
      # index writes included; mirrors SourceFile#mutated_constants.
      def self.mutator_receivers(file)
        receivers = []
        queue = [file.root]
        until queue.empty?
          node = queue.shift
          queue.concat(node.child_nodes.compact)
          mutator =
            (node.is_a?(Prism::CallNode) &&
              Static::SourceFile::CONST_MUTATORS
                .include?(node.name)) ||
            Static::SourceFile::INDEX_WRITES
              .any? { |type| node.is_a?(type) }
          next unless mutator && node.receiver

          receivers << node.receiver
        end
        receivers
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
        kinds = classifier(file)
        memos.filter_map do |memo|
          value = memo[:op][:node].value
          freeze_value(value, kinds.classify(value))
        end
      end

      # Plain `.freeze` only where the value is provably a string;
      # everything unproven gets Ractor.make_shareable, which is a
      # no-op for already-shareable values. This matters for
      # memoized classes (multi_json memoizes adapter classes):
      # `.freeze` on a Class freezes the class object and later
      # ivar writes on it raise FrozenError.
      def self.freeze_value(value, kind)
        return nil if kind == :shareable
        # Freezing or wrapping a sync primitive raises; leave the
        # finding in place for a human.
        return nil if kind == :sync_primitive
        return nil if frozen_call?(value)

        slice = value.location.slice
        replacement =
          if kind == :mutable_string
            parens?(value) ? "(#{slice}).freeze" : "#{slice}.freeze"
          else
            "Ractor.make_shareable(#{slice})"
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

        raw = source.dup.force_encoding(Encoding::BINARY)
        from = node.location.start_offset
        start = from.zero? ? 0 : (raw.rindex("\n", from - 1) || -1) + 1
        indent = raw[start...from].force_encoding(source.encoding)
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
        raw = source.dup.force_encoding(Encoding::BINARY)
        from = node.location.start_offset
        upto = node.location.end_offset
        start = from.zero? ? 0 : (raw.rindex("\n", from - 1) || -1) + 1
        if raw[start...from].match?(/\A[ \t]*\z/n)
          newline = raw.index("\n", upto)
          stop = newline ? newline + 1 : raw.length
          loop do
            newline = raw.index("\n", stop)
            break unless newline
            break unless raw[stop...newline].match?(/\A[ \t]*\z/n)

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
          @defined_depth = 0
          super
        end

        def visit_class_node(node)
          scoped(node.constant_path.location.slice, :class) do
            super(node)
          end
        end

        def visit_module_node(node)
          scoped(node.constant_path.location.slice, :module) do
            super(node)
          end
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
            {kind: kind, id: node.object_id,
             name: node.name, node: node}
          )
          super
        ensure
          @def_stack.pop
        end

        # A defined?(@x) that is not the recognized guard idiom
        # probes ivar presence; rewriting the read to Ractor
        # storage would make the probe unconditionally true, so
        # every op inside disqualifies its group (recorded as
        # :other).
        def visit_defined_node(node)
          @defined_depth += 1
          super
        ensure
          @defined_depth -= 1
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

        # class/module bodies open a fresh method scope: a def
        # inside a module nested under `class << self` defines an
        # instance method of that module, so the surrounding
        # singleton context and def stack must not leak in.
        def scoped(name, kind)
          saved_depth = @sclass_depth
          saved_stack = @def_stack
          @namespace.push({name: name, kind: kind})
          @sclass_depth = 0
          @def_stack = []
          yield
        ensure
          @sclass_depth = saved_depth
          @def_stack = saved_stack
          @namespace.pop
        end

        def record(node, kind, name)
          return if @namespace.empty?

          kind = :other if @defined_depth.positive?
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

          names = @namespace.map { |entry| entry[:name] }
          key = [names.join("::"), name.to_s]
          @groups[key] << {
            node: node, kind: kind, body: body,
            def_id: current_def && current_def[:id],
            def_name: current_def && current_def[:name],
            def_node: current_def && current_def[:node],
            class_owner: @namespace.last[:kind] == :class
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
        bundles = []
        if findings.any? { |f| f.check == "global-variables" }
          bundles += globals(file)
        end
        if findings.any? { |f| f.check == "class-variables" }
          bundles += class_variables(file)
        end
        bundles
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
        # The same bare @@name under two namespaces of one file is
        # usually same-file inheritance sharing one runtime
        # variable; converting either copy strands the other's
        # readers with a NameError.
        bare = collector.groups.keys
          .map { |key| key.split("/").last }
          .tally
        planned = []
        bundles = []
        collector.groups.each do |name, ops|
          next if bare[name.split("/").last] > 1

          writes = ops.select { |op| op[:kind] == :write }
          next unless writes.size == 1 && writes[0][:assignable]
          next unless (ops - writes).all? { |op| op[:kind] == :read }

          write = writes[0][:node]
          kind = classifier.classify(write.value)
          next if kind == :sync_primitive
          # A constructed object may gain singleton methods or be
          # mutated later (sinatra's @@eats_errors); wrapping it
          # in make_shareable freezes it and those break.
          next if Memoization.constructor?(write.value, classifier)

          shareable = kind == :shareable
          # A mutable value that would get deep-frozen must never be
          # the receiver of a call afterwards: `X[k] = v`, `X << v`
          # and friends would raise FrozenError at runtime. The same
          # goes for reads that escape into a local (`list = $x;
          # list << h`) or a call argument, where an alias can be
          # mutated out of sight. Reads of immutable values are
          # safe anywhere.
          unless shareable
            escapes = (ops - writes).any? do |op|
              id = op[:node].object_id
              collector.receiver_reads.include?(id) ||
                collector.escaping_reads.include?(id)
            end
            next if escapes
          end

          constant = yield(name.split("/").last)
          next unless constant.match?(/\A[A-Z][A-Z0-9_]*\z/)
          next if collector.taken_constants.include?(constant)

          # `$max` and `$MAX` both map to MAX; only the first may
          # take the name, the second stays a variable.
          target = [name.rpartition("/").first, constant]
          next if planned.include?(target)

          planned << target
          edits = [Autofix.new(
            start_offset: write.name_loc.start_offset,
            end_offset: write.name_loc.end_offset,
            replacement: constant,
            safety: :unsafe
          )]
          unless shareable
            value = write.value
            source = value.location.slice
            if value.is_a?(Prism::ArrayNode) &&
                value.opening_loc.nil?
              source = "[#{source}]"
            end
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
          bundles << Rewriters.bundle(ops, edits)
        end
        bundles.compact
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

        attr_reader :groups, :taken_constants, :receiver_reads,
          :escaping_reads

        def initialize(mode)
          @mode = mode
          @groups = Hash.new { |h, k| h[k] = [] }
          @taken_constants = []
          @receiver_reads = {}
          @escaping_reads = {}
          @namespace = []
          @def_depth = 0
          @block_depth = 0
          @conditional_depth = 0
          super()
        end

        def visit_call_node(node)
          receiver = node.receiver
          if receiver.is_a?(Prism::GlobalVariableReadNode) ||
              receiver.is_a?(Prism::ClassVariableReadNode)
            @receiver_reads[receiver.object_id] = true
          end
          arguments = node.arguments&.arguments || []
          arguments.each { |argument| mark_escape(argument) }
          super
        end

        # `list = $handlers; list << h` mutates the value through
        # an alias the receiver check cannot see; reads that flow
        # into a local or a call argument are recorded so mutable
        # values never get deep-frozen under them.
        %i[
          visit_local_variable_write_node
          visit_local_variable_or_write_node
          visit_local_variable_and_write_node
          visit_local_variable_operator_write_node
        ].each do |method|
          define_method(method) do |node| # audition:disable unsafe-calls
            mark_escape(node.value)
            super(node)
          end
        end

        # A write that only happens on some paths (`$verbose =
        # true if ENV[...]`) must stay a variable: readers get nil
        # on the untaken path, where a constant would raise
        # NameError.
        %i[
          visit_if_node
          visit_unless_node
          visit_case_node
          visit_case_match_node
          visit_while_node
          visit_until_node
          visit_and_node
          visit_or_node
          visit_rescue_modifier_node
        ].each do |method|
          define_method(method) do |node| # audition:disable unsafe-calls
            conditionally { super(node) }
          end
        end

        def conditionally
          @conditional_depth += 1
          yield
        ensure
          @conditional_depth -= 1
        end

        def visit_begin_node(node)
          if node.rescue_clause
            @conditional_depth += 1
            begin
              super
            ensure
              @conditional_depth -= 1
            end
          else
            super
          end
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

        def mark_escape(node)
          return unless node.is_a?(Prism::GlobalVariableReadNode) ||
            node.is_a?(Prism::ClassVariableReadNode)

          @escaping_reads[node.object_id] = true
        end

        def record_gvar(node, kind)
          name = node.name.to_s
          return if SKIP_GLOBALS.include?(name)

          @groups[name] << {
            node: node, kind: kind,
            assignable: @def_depth.zero? && @block_depth.zero? &&
              @namespace.empty? && @conditional_depth.zero?
          }
        end

        def record_cvar(node, kind)
          return if @namespace.empty?

          key = "#{@namespace.join("::")}/#{node.name}"
          @groups[key] << {
            node: node, kind: kind,
            assignable: @def_depth.zero? && @block_depth.zero? &&
              @conditional_depth.zero?
          }
        end
      end
    end
  end
end
