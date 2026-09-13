# frozen_string_literal: true

require "rbconfig"

module Audition
  module Static
    # Call sites into bundled gems whose compiled extensions do
    # not declare Ractor safety (rb_ext_ractor_safe), so calling
    # into them from a non-main Ractor raises Ractor::UnsafeError.
    # The extension's code is outside the scanned tree; the call
    # site is the only place a static pass can flag.
    #
    # Rules are derived from the target's own bundle, never from a
    # gem list: a pinned gem whose installed extension lacks the
    # declaration—or that pins a platform-specific build Audition
    # cannot inspect (the running Ruby's own copy of the extension
    # settles it when one is shipped)—gets its call sites
    # flagged, anchored to the
    # gem's own namespace (read from its entry file's module
    # nesting, or the require-path convention when the gem is not
    # installed). Matched calls taint: the value handed back is
    # presumed to still live in the extension, so calls chained
    # onto it, or on the local or ivar it is assigned to, are
    # flagged and keep the taint moving; a predicate ends the
    # chain, and freeze, tap, itself, and class pass it along
    # silently. Sorbet
    # annotations extend the reach—a sig param, T.let, or T.cast
    # typed with a constant under a flagged gem's namespace taints
    # the annotated variable the same way, and a plain type clears
    # the guess. A per-class pre-pass makes the body order-free:
    # a method whose return expression or sig return type is
    # rooted in a flagged namespace hands the taint to callers on
    # self, self.class, or the class's own constant, and an ivar
    # assigned such a value anywhere in the body—directly or
    # through its attr writer—is tainted throughout. A pass over
    # the whole tree first promotes classes that hold extension
    # values in their instances—or subclass one that does—to
    # rules of their own, so constructing or receiving one in
    # another file carries the taint across files.
    class GemCalls
      UNSAFE_WHY =
        "%{gem}'s compiled extension does not declare Ractor " \
        "safety (rb_ext_ractor_safe), so its methods raise " \
        "Ractor::UnsafeError (\"ractor unsafe method called from " \
        "not main ractor\") from any non-main Ractor."

      UNVERIFIED_WHY =
        "%{gem} pins a compiled extension Audition could not " \
        "inspect (the gem is not installed here). An extension " \
        "that does not declare Ractor safety " \
        "(rb_ext_ractor_safe) raises Ractor::UnsafeError from " \
        "any non-main Ractor; install the bundle to verify."

      MESSAGE =
        "%{receiver}.%{method} calls into %{gem}, whose compiled " \
        "extension does not declare Ractor safety"

      UNVERIFIED_MESSAGE =
        "%{receiver}.%{method} calls into %{gem}, which pins a " \
        "compiled extension Audition could not inspect"

      DERIVED_MESSAGE =
        "%{method} called on a value handed out by %{gem}'s " \
        "native extension"

      FIX =
        "Keep calls into %{gem} on the main Ractor and share " \
        "only extracted plain data (frozen strings, numbers) " \
        "between Ractors, or get the extension to declare " \
        "rb_ext_ractor_safe(true)."

      # Object/Kernel identity methods that never enter the
      # extension, even on a gem object.
      CORE_METHODS = Ractor.make_shareable(
        Set.new(
          %i[nil? is_a? kind_of? instance_of? respond_to? frozen?
            equal? class object_id itself hash tap then freeze]
        )
      )

      # Core methods that hand back the receiver—or, for class,
      # the extension's own class object: no finding, but a
      # tainted receiver's taint passes through.
      CHAIN_METHODS = Ractor.make_shareable(
        Set.new(%i[class itself tap freeze])
      )

      CHECK = "native-gem-calls"

      EMPTY_NESTING = Ractor.make_shareable([])

      # Predicates whose constant argument proves the receiver's
      # class when they gate a branch.
      TYPE_CHECKS = Ractor.make_shareable(
        Set.new(%i[is_a? kind_of? instance_of?])
      )

      EVAL_REOPENINGS = Ractor.make_shareable(
        Set.new(%i[class_eval module_eval])
      )

      # Methods that hand the receiver itself to their block.
      YIELD_SELF = Ractor.make_shareable(
        Set.new(%i[then yield_self])
      )

      EMPTY_SET = Ractor.make_shareable(Set.new)

      # What a stub has to show before its gem counts as compiled:
      # one source location holding this share of the gem's located
      # methods, across at least this many classes.
      STUB_SHARE = 0.6
      STUB_OWNERS = 2
      STUB_SOURCE = %r{# source://(\S+)}
      STUB_DEF = /\A\s*def [\w\[\]<>=!+\-*\/%~^&|?]/
      STUB_SCOPE = /\A\s*(?:class|module)\s+([A-Za-z0-9_:]+)/

      # Everything an object answers before any extension gets
      # involved: a bare call to anything else inside a reopened
      # bound class lands in the extension.
      RUBY_METHODS = Ractor.make_shareable(
        Set.new(
          [Object, Kernel, Module, Class].flat_map do |mod|
            mod.instance_methods + mod.private_instance_methods
          end
        )
      )

      # Core iterators hand elements to their block; these
      # positions carry the memo or index instead.
      BLOCK_MEMO_POSITIONS = Ractor.make_shareable(
        {each_with_object: 1, with_object: 1, each_with_index: 1,
         with_index: 1, inject: 0, reduce: 0}
      )

      # One flagged gem: verified means its installed extension
      # binary was read and lacks the declaration; unverified
      # means the lockfile proves compiled code exists but no
      # binary was available to read. A bound rule's namespace IS
      # the extension's own class or module—the gem namespace,
      # a constant assigned an extension-rooted value, or a
      # subclass of either—so reopening it defines methods on
      # extension instances; an unbound rule marks app code that
      # merely holds extension values.
      Rule = Data.define(:gem, :namespace, :verified, :bound) do
        def initialize(gem:, namespace:, verified:, bound: false)
          super
        end
      end

      # @param root [String] target root, where Gemfile.lock lives
      # @param stubs [Array<String>] the target's .rbi stubs
      # @param rules [Array<Rule>, nil] override bundle resolution
      def initialize(root:, stubs: [], rules: nil)
        @stubs = stubs
        @rules = rules || resolve(root)
        @nesting = EMPTY_NESTING
        @self_rule = nil
        @self_defs = EMPTY_SET
        @param_seeds = {}
        @return_taints = {}
        reset_seed_ledger
        index_rules
      end

      # @param paths [Array<String>] files to scan
      # @param progress [Progress] narrates the
      #   three passes this phase makes over the tree
      # @return [Array<Finding>]
      def analyze_paths(paths, progress: Progress::SILENT)
        return [] if @rules.empty?

        progress.stage("subclasses", total: paths.size)
        @rules += derived_class_rules(paths, progress)
        index_rules
        @param_seeds = {}
        reset_seed_ledger
        findings = {}
        progress.stage("scanning", total: paths.size)
        paths.each do |path|
          progress.tick
          source = read_source(path)
          findings[path] = analyze_file(path, source) if source
        end
        settle_seeds(findings, progress)
        findings.values.flatten(1)
      end

      private

      # A call in one file seeds a parameter of a method defined
      # in another, so a file walked before the call was seen has
      # to walk again. Rounds are capped: each one costs a walk of
      # every file the round before it taught something new.
      SEED_ROUNDS = 3

      def reset_seed_ledger
        @seed_clock = 0
        @seed_at = {}
        @def_keys = {}
        @walked_at = {}
      end

      def settle_seeds(findings, progress = Progress::SILENT)
        SEED_ROUNDS.times do |round|
          stale = findings.keys.select { |path| stale?(path) }
          break if stale.empty?

          progress.stage("settling #{round + 1}", total: stale.size)
          stale.each do |path|
            progress.tick
            source = read_source(path)
            findings[path] = analyze_file(path, source) if source
          end
        end
      end

      def stale?(path)
        walked = @walked_at[path]
        return false unless walked

        @def_keys[path].any? do |key|
          (@seed_at[key] || -1) > walked
        end
      end

      def read_source(path)
        File.read(path)
      rescue SystemCallError
        nil
      end

      def resolve(root)
        lockfile = File.join(root, "Gemfile.lock")
        return [] unless File.file?(lockfile)

        pinned(lockfile).flat_map do |name, version, platform|
          rules_for(name, version, platform)
        end
      end

      # Lockfile rows collapse platform variants into one gem with
      # a platform mark: a platform suffix on any variant proves
      # the gem ships compiled code.
      def pinned(lockfile)
        rows = {}
        File.foreach(lockfile) do |line|
          match = line.match(/\A    ([A-Za-z0-9_-]+) \(([^)\s]+)\)/)
          next unless match

          version, platform =
            match[2].match(/\A([0-9][\w.]*?)(?:-(.+))?\z/)&.captures
          next unless version

          row = rows[match[1]] ||= [match[1], version, nil]
          row[2] ||= platform
        end
        rows.values
      end

      # An installed copy is the best evidence. Without one, the
      # generated type stubs in the target's own tree name the
      # classes whose methods are not Ruby-defined, and a
      # platform pin proves compiled code ships under the gem's
      # own name: both hold, so both are flagged.
      def rules_for(name, version, platform)
        spec = installed_spec(name, version)
        return Array(installed_rule(name, spec)) if spec

        namespaces = stub_namespaces(name, version)
        namespaces += [convention_namespace(name)] if platform
        namespaces.uniq.filter_map { |ns| unverified_rule(name, ns) }
      end

      def installed_rule(name, spec)
        compiled = Target.compiled_for(spec)
        if compiled.any?
          return nil if compiled.all? { |path| declares_safety?(path) }

          Rule.new(gem: name, namespace: namespace_for(name, spec),
            verified: true, bound: true)
        elsif spec.extensions.any?
          unverified_rule(name, namespace_for(name, spec))
        end
      end

      # A pin with no readable binary—a platform build the
      # bundle did not install, or a default gem whose extension
      # lives outside its require paths—can still be judged when
      # the running Ruby ships the same extension: Ruby's own
      # binary is the evidence.
      def unverified_rule(name, namespace)
        shipped = ruby_shipped_extension(name)
        unless shipped
          return Rule.new(gem: name, namespace: namespace,
            verified: false, bound: true)
        end
        return nil if declares_safety?(shipped)

        Rule.new(gem: name, namespace: namespace, verified: true,
          bound: true)
      end

      def ruby_shipped_extension(name)
        base = File.join(RbConfig::CONFIG["archdir"],
          name.tr("-", "/"))
        Dir["#{base}.{so,bundle}"].first
      end

      # Bundler hides gems outside the current bundle from
      # find_by_name, so fall back to reading gemspecs straight
      # from the installed specification directories.
      def installed_spec(name, version)
        Gem::Specification.find_by_name(name, version)
      rescue Gem::LoadError
        Gem.path.each do |base|
          pattern = File.join(base, "specifications",
            "#{name}-#{version}{,-*}.gemspec")
          Dir[pattern].each do |path|
            spec = Gem::Specification.load(path)
            return spec if spec&.name == name
          end
        end
        nil
      end

      def declares_safety?(path)
        File.binread(path).include?(NativeExtensions::SYMBOL)
      rescue SystemCallError
        false
      end

      # A generated type stub is the target's own record of what a
      # gem's methods look like. The generator writes each method's
      # Ruby source location, and methods a compiled extension
      # defines all land on the one line that loads it: a single
      # location holding most of a gem's methods, spread over
      # several classes, is that shape. A metaprogramming block
      # defines its methods on the class it sits in, so one owner
      # is not evidence. The owners of that cluster are the
      # extension's own classes, which name it better than any
      # convention can.
      # Generators name a gem's stub for the gem and version it
      # documents, which identifies it wherever the generator was
      # told to write.
      def stub_namespaces(name, version)
        wanted = "#{name}@#{version}.rbi"
        path = @stubs.find { |s| File.basename(s) == wanted }
        return [] unless path

        clusters = stub_clusters(path)
        located = clusters.sum { |_, owners| owners.values.sum }
        return [] if located.zero?

        owners = clusters.each_value.max_by { |o| o.values.sum }
        return [] if owners.size < STUB_OWNERS ||
          owners.values.sum < located * STUB_SHARE

        owners.keys
      end

      def stub_clusters(path)
        clusters = Hash.new { |h, k| h[k] = Hash.new(0) }
        scope = []
        indents = []
        source = nil
        File.foreach(path) do |raw|
          line = raw.rstrip
          next if line.empty?

          indent = line[/\A */].size
          while indents.any? && indent <= indents.last
            indents.pop
            scope.pop
          end
          if (match = line.match(STUB_SCOPE))
            scope.push(stub_scope_name(scope, match[1]))
            indents.push(indent)
            source = nil
          elsif (match = line.match(STUB_SOURCE))
            source = match[1]
          else
            if source && scope.last && line.match?(STUB_DEF)
              clusters[source][scope.last] += 1
            end
            source = nil
          end
        end
        clusters
      rescue SystemCallError
        {}
      end

      # Stubs write top-level definitions under their full path and
      # nested ones relative to the enclosing scope.
      def stub_scope_name(scope, written)
        scope.empty? ? written : "#{scope.last}::#{written}"
      end

      # The entry file's module nesting names the gem's namespace
      # more reliably than name conventions do.
      def namespace_for(name, spec)
        entry = spec.full_require_paths
          .map { |rp| File.join(rp, "#{name.tr("-", "/")}.rb") }
          .find { |path| File.file?(path) }
        (entry && nesting_namespace(entry)) ||
          convention_namespace(name)
      end

      def nesting_namespace(path)
        result = Prism.parse(File.read(path))
        return nil unless result.success?

        names = []
        body = result.value.statements.body
        while (mod = sole_module(body))
          names << mod.constant_path.location.slice
            .delete_prefix("::")
          body =
            mod.body.is_a?(Prism::StatementsNode) ? mod.body.body : []
        end
        names.join("::") unless names.empty?
      rescue SystemCallError
        nil
      end

      def sole_module(statements)
        mods = statements.select do |node|
          node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)
        end
        mods.first if mods.size == 1
      end

      def convention_namespace(name)
        name.split("-").map do |seg|
          seg.split("_").map(&:capitalize).join
        end.join("::")
      end

      # Each pass may learn argument seeds and computed return
      # taints that change what an earlier line would flag, so
      # the file re-walks until a pass learns nothing new and
      # only that pass's findings stand.
      def analyze_file(path, source)
        file = SourceFile.new(source: source, path: path)
        return [] unless file.valid_syntax?

        @path = path

        @return_taints = {}
        @def_keys[path] = Set.new
        scan = nil
        loop do
          before = knowledge_size
          @registry = nil
          @singleton = false
          @nesting = EMPTY_NESTING
          @self_rule = nil
          @self_defs = EMPTY_SET
          scan = Scan.new(path: path, findings: [], producers: {})
          walk(file.root, {}, {}, scan)
          break if knowledge_size == before
        end
        @walked_at[path] = @seed_clock
        scan.findings
      end

      # Seeds and return taints only grow, so the loop stops at
      # the first pass that learns nothing.
      def knowledge_size
        @param_seeds.sum { |_, seeds| seeds.size } +
          @return_taints.size
      end

      Scan = Data.define(:path, :findings, :producers)

      # Ordered walk carrying the taint state: tainted maps a local
      # name to the rule whose call produced its value, ivars does
      # the same for instance variables; producers remembers which
      # call nodes are rooted in a flagged namespace so a chained
      # call or an assignment can pick the taint up. Defs open
      # fresh local scopes (seeded from the preceding sig); classes
      # and modules open fresh ivar scopes; blocks close over the
      # enclosing.
      def walk(node, tainted, ivars, scan)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          registry, singleton, nesting = @registry, @singleton, @nesting
          self_rule, self_defs = @self_rule, @self_defs
          bound = source_rule(node.constant_path.location.slice)
          @self_rule = bound&.bound ? bound : nil
          @self_defs = @self_rule ? body_defs(node.body) : EMPTY_SET
          @nesting = nested_scope(node)
          @registry, @singleton = build_registry(node), false
          each_child(node) do |child|
            walk(child, {}, @registry.ivars[:instance].dup, scan)
          end
          @registry, @singleton, @nesting = registry, singleton, nesting
          @self_rule, @self_defs = self_rule, self_defs
        when Prism::SingletonClassNode
          if @registry && node.expression.is_a?(Prism::SelfNode)
            singleton = @singleton
            @singleton = true
            each_child(node) do |child|
              walk(child, {}, @registry.ivars[:singleton].dup, scan)
            end
            @singleton = singleton
          else
            registry = @registry
            @registry = nil
            each_child(node) { |child| walk(child, {}, {}, scan) }
            @registry = registry
          end
        when Prism::DefNode
          walk_def(node, nil, ivars, scan)
        when Prism::StatementsNode
          sig = nil
          node.body.each do |child|
            if child.is_a?(Prism::DefNode)
              walk_def(child, sig, ivars, scan)
            else
              walk(child, tainted, ivars, scan)
              guard_taint(child, tainted, ivars)
            end
            sig = sig_node?(child) ? child : nil
          end
        when Prism::CaseNode
          walk_case(node, tainted, ivars, scan)
        when Prism::IfNode
          walk_if(node, tainted, ivars, scan)
        when Prism::CallNode
          if (rule = reopening_rule(node))
            walk_reopening(node, rule, tainted, ivars, scan)
          else
            walk_call(node, tainted, ivars, scan)
          end
        when Prism::LocalVariableWriteNode,
             Prism::LocalVariableOrWriteNode,
             Prism::LocalVariableAndWriteNode,
             Prism::LocalVariableOperatorWriteNode
          walk(node.value, tainted, ivars, scan)
          rule = value_rule(node.value, tainted, ivars, scan)
          rule ? tainted[node.name] = rule : tainted.delete(node.name)
        when Prism::InstanceVariableWriteNode,
             Prism::InstanceVariableOrWriteNode,
             Prism::InstanceVariableAndWriteNode,
             Prism::InstanceVariableOperatorWriteNode
          walk(node.value, tainted, ivars, scan)
          rule = value_rule(node.value, tainted, ivars, scan)
          rule ? ivars[node.name] = rule : ivars.delete(node.name)
        when Prism::MultiWriteNode
          each_child(node) { |child| walk(child, tainted, ivars, scan) }
          multi_targets(node).each do |target|
            case target
            when Prism::LocalVariableTargetNode
              tainted.delete(target.name)
            when Prism::InstanceVariableTargetNode
              ivars.delete(target.name)
            end
          end
        else
          each_child(node) { |child| walk(child, tainted, ivars, scan) }
        end
      end

      # Branches run on their own copy: a value one branch
      # assigns may still be live after the branch, and one
      # every branch replaces is not.
      def walk_if(node, tainted, ivars, scan)
        walk(node.predicate, tainted, ivars, scan)
        key, rule = type_check(node.predicate)
        branches = []
        if node.statements
          copies = [tainted.dup, ivars.dup]
          with_taint(key, rule, *copies) do
            walk(node.statements, *copies, scan)
          end
          branches << copies
        end
        if node.subsequent
          copies = [tainted.dup, ivars.dup]
          walk(node.subsequent, *copies, scan)
          branches << copies
        end
        merge_branches(tainted, ivars, branches,
          node.statements && node.subsequent)
      end

      def merge_branches(tainted, ivars, branches, total)
        branches.each do |branch_tainted, branch_ivars|
          branch_tainted.each { |k, v| tainted[k] ||= v }
          branch_ivars.each { |k, v| ivars[k] ||= v }
        end
        return unless total

        tainted.delete_if do |k, _|
          branches.none? { |t, _| t.key?(k) }
        end
        ivars.delete_if do |k, _|
          branches.none? { |_, i| i.key?(k) }
        end
      end

      def walk_def(node, sig, ivars, scan)
        singleton_def = node.receiver.is_a?(Prism::SelfNode)
        side = (@singleton || singleton_def) ? :singleton : :instance
        tainted = param_taints(node, sig, side)
        if singleton_def && !@singleton
          singleton = @singleton
          @singleton = true
          ivars = @registry ? @registry.ivars[:singleton].dup : {}
          each_child(node) { |child| walk(child, tainted, ivars, scan) }
          @singleton = singleton
        else
          each_child(node) { |child| walk(child, tainted, ivars, scan) }
        end
        note_return_taint(node, side, scan)
      end

      # Sig taints seed the def's scope, then call sites already
      # walked add argument taints for params the sig leaves
      # untyped or erased; a plain constant type keeps the param
      # clean.
      def param_taints(node, sig, side)
        taints = sig ? sig_taints(sig) : {}
        seeds = seeds_for(side, node.name)
        return taints unless seeds

        plain = sig ? plain_params(sig) : EMPTY_SET
        seeds.each do |key, rule|
          name = seed_param_name(node.parameters, key)
          next if name.nil? || taints.key?(name) ||
            plain.include?(name)

          taints[name] = rule
        end
        taints
      end

      # A call through the module's own name reaches an instance
      # method the module extended itself with.
      def seeds_for(side, name)
        key = [seed_scope, side, name]
        note_def_key(key)
        seeds = @param_seeds[key]
        return seeds if seeds || side != :instance ||
          !@registry&.self_extended

        fallback = [seed_scope, :singleton, name]
        note_def_key(fallback)
        @param_seeds[fallback]
      end

      # What this file's definitions would consume, so a seed
      # learned later can call the file back.
      def note_def_key(key)
        @def_keys[@path]&.add(key)
      end

      def seed_param_name(params, key)
        return nil unless params

        if key.is_a?(Integer)
          requireds = params.requireds
          param = if key < requireds.size
            requireds[key]
          else
            params.optionals[key - requireds.size]
          end
          case param
          when Prism::RequiredParameterNode,
               Prism::OptionalParameterNode
            param.name
          end
        else
          params.keywords.find do |kw|
            kw.respond_to?(:name) && kw.name == key
          end&.name
        end
      end

      # A def whose final expression produces taint hands it to
      # callers even when its sig says nothing; predicates stay
      # plain. Learned during one pass, applied on the next.
      def note_return_taint(node, side, scan)
        return if node.name.end_with?("?")

        expr = def_return_expr(node)
        rule = expr && scan.producers[expr.object_id]
        @return_taints[[seed_scope, side, node.name]] = rule if rule
      end

      def seed_scope
        @registry&.class_name
      end

      # A bare or self call names a method in the scope being
      # walked. A constant receiver names the scope itself, by its
      # last segment: a call site and a definition rarely spell
      # the path the same way.
      def seed_key(node)
        case node.receiver
        when nil, Prism::SelfNode
          [seed_scope, @singleton ? :singleton : :instance,
            node.name]
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          name = node.receiver.location.slice
            .delete_prefix("::").split("::").last
          [name, :singleton, node.name]
        end
      end

      # The block walks after the call resolves: a flagged call's
      # block iterates values living in the same extension, so its
      # element parameters carry the taint.
      def walk_call(node, tainted, ivars, scan)
        block = node.block
        each_child(node) do |child|
          walk(child, tainted, ivars, scan) unless child.equal?(block)
        end
        rule = visit_call(node, tainted, ivars, scan) ||
          yielded_self_rule(node, tainted, ivars, scan)
        note_argument_taints(node, tainted, ivars, scan)
        return unless block

        if rule && block.is_a?(Prism::BlockNode)
          walk_block(node, rule, tainted, ivars, scan)
        else
          walk(block, tainted, ivars, scan)
        end
      end

      # A tainted argument seeds the named method's parameter for
      # the passes that follow.
      def note_argument_taints(node, tainted, ivars, scan)
        key = seed_key(node)
        return unless key

        args = node.arguments&.arguments
        return unless args

        args.each_with_index do |arg, i|
          if arg.is_a?(Prism::KeywordHashNode)
            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode) &&
                assoc.key.is_a?(Prism::SymbolNode)

              note_seed(key, assoc.key.unescaped.to_sym,
                value_rule(assoc.value, tainted, ivars, scan))
            end
          else
            note_seed(key, i,
              value_rule(arg, tainted, ivars, scan))
          end
        end
      end

      def note_seed(key, param, rule)
        return unless rule

        seeds = (@param_seeds[key] ||= {})
        fresh = !seeds.key?(param)
        seeds[param] = rule
        @seed_at[key] = (@seed_clock += 1) if fresh
      end

      # then and yield_self pass the receiver straight in, so
      # the block parameter stands for the receiver.
      def yielded_self_rule(node, tainted, ivars, scan)
        return nil unless YIELD_SELF.include?(node.name)

        taint_source(node, tainted, ivars, scan) ||
          receiver_rule(node.receiver)
      end

      # What an expression hands over: a variable read carries
      # whatever the variable holds, self carries the body's own
      # binding, anything else carries what the walk recorded.
      def value_rule(node, tainted, ivars, scan)
        case node
        when Prism::LocalVariableReadNode then tainted[node.name]
        when Prism::InstanceVariableReadNode then ivars[node.name]
        when Prism::SelfNode then @singleton ? nil : @self_rule
        else scan.producers[node.object_id]
        end
      end

      def walk_block(node, rule, tainted, ivars, scan)
        names = element_params(node)
        saved = names.map { |n| [n, tainted.key?(n), tainted[n]] }
        names.each { |n| tainted[n] = rule }
        each_child(node.block) do |child|
          walk(child, tainted, ivars, scan)
        end
        saved.each do |name, had, prev|
          had ? tainted[name] = prev : tainted.delete(name)
        end
      end

      def element_params(node)
        params = node.block.parameters
        skip = BLOCK_MEMO_POSITIONS[node.name]
        case params
        when Prism::NumberedParametersNode
          (1..params.maximum).filter_map do |i|
            :"_#{i}" unless skip == i - 1
          end
        when Prism::BlockParametersNode
          names = []
          (params.parameters&.requireds || [])
            .each_with_index do |param, i|
              collect_param_names(param, names) unless skip == i
            end
          names
        else
          []
        end
      end

      def collect_param_names(param, names)
        case param
        when Prism::RequiredParameterNode,
             Prism::LocalVariableTargetNode
          names << param.name
        when Prism::MultiTargetNode
          [*param.lefts, param.rest, *param.rights].compact
            .each { |part| collect_param_names(part, names) }
        end
      end

      def each_child(node, &block)
        node.child_nodes.compact.each(&block)
      end

      def nested_scope(node)
        slice = node.constant_path.location.slice
        segments = slice.delete_prefix("::").split("::")
        slice.start_with?("::") ? segments : [*@nesting, *segments]
      end

      def multi_targets(node)
        [*node.lefts, node.rest, *node.rights].compact
      end

      # A when clause matching the subject against a flagged
      # constant proves its type inside the branch; if every
      # branch proves the same rule, the else clause sees that
      # value too, and a branch handing the value back makes the
      # whole case expression a producer.
      def walk_case(node, tainted, ivars, scan)
        walk(node.predicate, tainted, ivars, scan) if node.predicate
        key = node.predicate && taint_key(node.predicate)
        rules = node.conditions.map { |c| key ? when_rule(c) : nil }
        produced = nil
        node.conditions.each_with_index do |clause, i|
          clause.conditions.each do |cond|
            walk(cond, tainted, ivars, scan) unless constant_type?(cond)
          end
          next unless clause.statements

          with_taint(key, rules[i], tainted, ivars) do
            walk(clause.statements, tainted, ivars, scan)
            produced ||= branch_rule(clause.statements, key, rules[i], scan)
          end
        end
        if node.else_clause
          shared = (rules.uniq.size == 1) ? rules.first : nil
          with_taint(key, shared, tainted, ivars) do
            walk(node.else_clause, tainted, ivars, scan)
            produced ||=
              branch_rule(node.else_clause.statements, key, shared, scan)
          end
        end
        scan.producers[node.object_id] = produced if produced
      end

      # One rule only when every condition in the clause is a
      # constant resolving to it: mixed or non-constant
      # conditions are not a class match.
      def when_rule(clause)
        rules = clause.conditions.map do |cond|
          constant_type?(cond) ? source_rule(cond.location.slice) : nil
        end
        (rules.uniq.size == 1) ? rules.first : nil
      end

      # The value a branch hands back, seen through trailing
      # modifier conditionals.
      def branch_rule(statements, key, rule, scan)
        tail = statements&.body&.last
        while tail.is_a?(Prism::IfNode) || tail.is_a?(Prism::UnlessNode)
          tail = tail.statements&.body&.last
        end
        return nil unless tail

        scan.producers[tail.object_id] ||
          (rule if key && taint_key(tail) == key)
      end

      # Reopening a bound name through class_eval defines methods
      # on the extension's own class; the eval call itself never
      # enters the extension.
      def reopening_rule(node)
        return nil unless EVAL_REOPENINGS.include?(node.name) &&
          node.block.is_a?(Prism::BlockNode)

        rule = receiver_rule(node.receiver)
        rule&.bound ? rule : nil
      end

      def walk_reopening(node, rule, tainted, ivars, scan)
        self_rule, self_defs = @self_rule, @self_defs
        @self_rule = rule
        @self_defs = body_defs(node.block.body)
        each_child(node) { |child| walk(child, tainted, ivars, scan) }
        @self_rule, @self_defs = self_rule, self_defs
      end

      # Names the reopened body itself defines: self-calls on
      # these stay ordinary Ruby.
      def body_defs(body)
        defs = Set.new
        statements =
          body.is_a?(Prism::StatementsNode) ? body.body : []
        statements.each do |stmt|
          case stmt
          when Prism::DefNode
            defs << stmt.name
          when Prism::CallNode
            roles = ATTR_ROLES[stmt.name]
            next unless roles && stmt.receiver.nil?

            args = stmt.arguments&.arguments || []
            args.grep(Prism::SymbolNode).each do |sym|
              defs << sym.unescaped.to_sym
              if roles.include?(:writer)
                defs << :"#{sym.unescaped}="
              end
            end
          end
        end
        defs
      end

      # The store slot a subject narrows to: a local or an
      # instance variable; anything else cannot hold taint.
      def taint_key(node)
        case node
        when Prism::LocalVariableReadNode then [:local, node.name]
        when Prism::InstanceVariableReadNode then [:ivar, node.name]
        end
      end

      def with_taint(key, rule, tainted, ivars)
        return yield unless key && rule

        store = (key[0] == :local) ? tainted : ivars
        name = key[1]
        had, prev = store.key?(name), store[name]
        store[name] = rule
        yield
        had ? store[name] = prev : store.delete(name)
      end

      # A guard that bails unless the variable is one of a
      # flagged gem's classes proves its type for whatever
      # follows in the surrounding sequence.
      def guard_taint(child, tainted, ivars)
        return unless child.is_a?(Prism::UnlessNode) &&
          terminates?(child.statements)

        key, rule = type_check(child.predicate)
        return unless key && rule

        store = (key[0] == :local) ? tainted : ivars
        store[key[1]] = rule
      end

      def terminates?(statements)
        last = statements&.body&.last
        last.is_a?(Prism::ReturnNode) || last.is_a?(Prism::NextNode) ||
          last.is_a?(Prism::BreakNode) ||
          (last.is_a?(Prism::CallNode) && last.name == :raise)
      end

      # x.is_a?(Some::Const) as a type proof for x, through the
      # left side of a && chain.
      def type_check(predicate)
        node = predicate
        node = node.left while node.is_a?(Prism::AndNode)
        return unless node.is_a?(Prism::CallNode) &&
          TYPE_CHECKS.include?(node.name) && node.receiver

        key = taint_key(node.receiver)
        return unless key

        args = node.arguments&.arguments
        return unless args&.size == 1 && constant_type?(args.first)

        rule = source_rule(args.first.location.slice)
        [key, rule] if rule
      end

      # Classes whose instances hold extension values—an ivar or
      # method rooted in a flagged namespace—become rules under
      # their own qualified name: constructing one, or receiving
      # one through a sig or annotation, taints in any file. A
      # subclass of a promoted or flagged class is promoted too,
      # and so is a constant assigned a value rooted in a flagged
      # namespace, the way protobuf-style generated Ruby binds
      # extension classes to its own names.
      def derived_class_rules(paths, progress = Progress::SILENT)
        found = {}
        mixins = []
        @nesting = EMPTY_NESTING
        paths.each do |path|
          progress.tick
          source = read_source(path)
          next unless source

          result = Prism.parse(source)
          next unless result.success?

          collect_classes(result.value, [], found)
          collect_mixins(result.value, [], mixins)
        end
        settle_subclasses(found)
        settle_mixins(found, mixins)
        found.values.filter_map { |info| info[:rule] }
      end

      # A mixin's instance methods run with the host as self:
      # include and prepend bind self to a host instance, extend
      # to the host itself. Either way, a module mixed into a
      # name bound to an extension value hands that value out
      # through self.
      MIXINS = Ractor.make_shareable(
        Set.new(%i[include prepend extend])
      )

      def collect_mixins(node, nesting, out)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          path = node.constant_path.location.slice
            .delete_prefix("::")
          return each_child(node) do |child|
            collect_mixins(child, [*nesting, path], out)
          end
        when Prism::CallNode
          note_mixin(node, nesting, out)
        end
        each_child(node) { |child| collect_mixins(child, nesting, out) }
      end

      # A bare call mixes into the body it sits in; a receiver
      # names the host itself.
      def note_mixin(node, nesting, out)
        return unless MIXINS.include?(node.name)

        host = case node.receiver
        when nil then nesting.last
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          node.receiver.location.slice.delete_prefix("::")
        end
        return unless host

        Array(node.arguments&.arguments).each do |arg|
          next unless constant_type?(arg)

          out << [host, arg.location.slice.delete_prefix("::"),
            nesting]
        end
      end

      def settle_mixins(found, mixins)
        loop do
          changed = false
          mixins.each do |host, mixin, nesting|
            info = found[mixin] ||= {rule: nil, superclass: nil,
                                     nesting: nesting}
            next if info[:rule]

            rule = resolve_name(host, nesting, found)
            next unless rule&.bound

            info[:rule] = derived_rule(rule, mixin, bound: true)
            changed = true
          end
          break unless changed
        end
      end

      # A reference resolves the way Ruby would: against each
      # level of the enclosing nesting, then as written.
      def resolve_name(name, nesting, found)
        nesting.size.downto(0) do |depth|
          candidate = [*nesting.first(depth), name].join("::")
          rule = namespace_rule(candidate) ||
            found.dig(candidate, :rule)
          return rule if rule
        end
        nil
      end

      def collect_classes(node, nesting, found)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          path = node.constant_path.location.slice
            .delete_prefix("::")
          note_class(node, nesting, path, found) if
            node.is_a?(Prism::ClassNode)
          return each_child(node) do |child|
            collect_classes(child, [*nesting, path], found)
          end
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode,
             Prism::ConstantPathWriteNode,
             Prism::ConstantPathOrWriteNode
          note_constant(node, nesting, found)
        end
        each_child(node) { |child| collect_classes(child, nesting, found) }
      end

      # A constant bound to an extension-rooted value is the value
      # under a new name; the name inherits the rule.
      def note_constant(node, nesting, found)
        path = if node.respond_to?(:target)
          node.target.location.slice.delete_prefix("::")
        else
          node.name.to_s
        end
        fqn = [*nesting, path].join("::")
        return if namespace_rule(fqn) || found.dig(fqn, :rule)

        @nesting = nesting
        taint = prepass_rule(node.value, :instance, EMPTY_REGISTRY)
        return unless taint

        found[fqn] = {rule: derived_rule(taint, fqn, bound: true),
                      superclass: nil, nesting: nesting}
      end

      def note_class(node, nesting, path, found)
        fqn = [*nesting, path].join("::")
        return if namespace_rule(fqn)

        @nesting = [*nesting, path]
        registry = build_registry(node)
        taint = registry.ivars[:instance].values.first ||
          registry.methods[:instance].values.first
        superclass = node.superclass
        info = found[fqn] ||= {rule: nil, superclass: nil,
                               nesting: nesting}
        info[:rule] ||= taint && derived_rule(taint, fqn)
        if info[:superclass].nil? && constant_type?(superclass)
          info[:superclass] =
            superclass.location.slice.delete_prefix("::")
        end
      end

      def derived_rule(taint, fqn, bound: false)
        Rule.new(gem: taint.gem, namespace: fqn,
          verified: taint.verified, bound: bound)
      end

      # Promotion follows inheritance to a fixpoint: the superclass
      # reference resolves the way Ruby would, against each level
      # of the subclass's own nesting, then as written.
      def settle_subclasses(found)
        loop do
          changed = false
          found.each do |fqn, info|
            next if info[:rule] || info[:superclass].nil?

            parent = superclass_rule(info, found)
            next unless parent

            info[:rule] = derived_rule(parent, fqn,
              bound: parent.bound)
            changed = true
          end
          break unless changed
        end
      end

      def superclass_rule(info, found)
        resolve_name(info[:superclass], info[:nesting], found)
      end

      # Pre-pass results for one class or module body: methods
      # whose return value is rooted in a flagged namespace and
      # ivars assigned such a value, split by definition side.
      Registry = Data.define(:class_name, :methods, :ivars,
        :self_extended)

      EMPTY_REGISTRY = Ractor.make_shareable(
        Registry.new(class_name: "",
          methods: {instance: {}, singleton: {}},
          ivars: {instance: {}, singleton: {}},
          self_extended: false)
      )

      Entry = Data.define(:side, :name, :return_expr, :ivar_writes,
        :writer_calls)

      ATTR_ROLES = Ractor.make_shareable(
        {attr_accessor: %i[reader writer], attr_reader: %i[reader],
         attr_writer: %i[writer]}
      )

      WRITER_NAME = /\A[a-z_]\w*=\z/

      # Collects the body's defs, attr declarations, and ivar
      # writes, then settles taint to a fixpoint, so a factory
      # defined below its callers still taints them.
      def build_registry(node)
        registry = Registry.new(
          class_name: node.constant_path.location.slice
            .delete_prefix("::"),
          methods: {instance: {}, singleton: {}},
          ivars: {instance: {}, singleton: {}},
          self_extended: self_extended?(node.body)
        )
        entries = []
        attrs = {instance: {reader: [], writer: []},
                 singleton: {reader: [], writer: []}}
        body = node.body
        if body.is_a?(Prism::StatementsNode)
          collect_entries(body.body, :instance, entries, attrs,
            registry)
        end
        settle(registry, entries, attrs)
        registry
      end

      # extend self and a bare module_function make the body's
      # instance methods singleton methods too, so a call through
      # the module's own name reaches them.
      def self_extended?(body)
        return false unless body.is_a?(Prism::StatementsNode)

        body.body.any? do |stmt|
          next false unless stmt.is_a?(Prism::CallNode) &&
            stmt.receiver.nil?

          case stmt.name
          when :extend
            Array(stmt.arguments&.arguments)
              .any?(Prism::SelfNode)
          when :module_function then stmt.arguments.nil?
          end
        end
      end

      def collect_entries(statements, side, entries, attrs, registry)
        sig = nil
        statements.each do |stmt|
          case stmt
          when Prism::DefNode
            def_side =
              stmt.receiver.is_a?(Prism::SelfNode) ? :singleton : side
            entries << def_entry(stmt, def_side)
            note_sig_return(sig, stmt, def_side, registry)
          when Prism::SingletonClassNode
            if stmt.expression.is_a?(Prism::SelfNode) &&
                stmt.body.is_a?(Prism::StatementsNode)
              collect_entries(stmt.body.body, :singleton, entries,
                attrs, registry)
            end
          when Prism::CallNode
            collect_attr(stmt, side, attrs)
          when Prism::InstanceVariableWriteNode,
               Prism::InstanceVariableOrWriteNode
            entries << Entry.new(side: :singleton, name: nil,
              return_expr: nil,
              ivar_writes: [[stmt.name, stmt.value]],
              writer_calls: [])
          end
          sig = sig_node?(stmt) ? stmt : nil
        end
      end

      # A sig return type under a flagged namespace marks the
      # method as handing out extension values, body regardless.
      def note_sig_return(sig, def_node, side, registry)
        return unless sig

        returns = sig_chain_call(sig, :returns)
        args = returns&.arguments&.arguments
        rule = args && args.size == 1 && type_rule(args[0])
        registry.methods[side][def_node.name] = rule if rule
      end

      def collect_attr(call, side, attrs)
        roles = ATTR_ROLES[call.name]
        return unless roles && call.receiver.nil?

        args = call.arguments&.arguments || []
        args.grep(Prism::SymbolNode).each do |sym|
          name = sym.unescaped.to_sym
          roles.each { |role| attrs[side][role] << name }
        end
      end

      def def_entry(node, side)
        ivar_writes = []
        writer_calls = []
        scan_def_body(node.body, ivar_writes, writer_calls)
        Entry.new(side: side, name: node.name,
          return_expr: def_return_expr(node),
          ivar_writes: ivar_writes, writer_calls: writer_calls)
      end

      def scan_def_body(node, ivar_writes, writer_calls)
        return if node.nil? || node.is_a?(Prism::ClassNode) ||
          node.is_a?(Prism::ModuleNode) ||
          node.is_a?(Prism::SingletonClassNode) ||
          node.is_a?(Prism::DefNode)

        case node
        when Prism::InstanceVariableWriteNode,
             Prism::InstanceVariableOrWriteNode
          ivar_writes << [node.name, node.value]
        when Prism::CallNode
          args = node.arguments&.arguments
          if node.receiver && args && args.size == 1 &&
              node.name.match?(WRITER_NAME)
            writer_calls << [node.name.to_s.chomp("=").to_sym,
              args.first]
          end
        end
        node.child_nodes.compact.each do |child|
          scan_def_body(child, ivar_writes, writer_calls)
        end
      end

      def def_return_expr(node)
        body = node.body
        body = body.statements if body.is_a?(Prism::BeginNode)
        body.body.last if body.is_a?(Prism::StatementsNode)
      end

      def settle(registry, entries, attrs)
        loop do
          changed = false
          entries.each do |entry|
            changed = true if settle_entry(entry, registry, attrs)
          end
          changed = true if settle_readers(registry, attrs)
          break unless changed
        end
      end

      # An attr reader over a tainted ivar hands the taint out
      # like a method returning it would.
      def settle_readers(registry, attrs)
        changed = false
        %i[instance singleton].each do |side|
          attrs[side][:reader].each do |name|
            next if registry.methods[side][name]

            rule = registry.ivars[side][:"@#{name}"]
            if rule
              registry.methods[side][name] = rule
              changed = true
            end
          end
        end
        changed
      end

      def settle_entry(entry, registry, attrs)
        changed = false
        if entry.name && !registry.methods[entry.side][entry.name] &&
            (rule = return_rule(entry.return_expr, entry.side, registry))
          registry.methods[entry.side][entry.name] = rule
          changed = true
        end
        entry.ivar_writes.each do |ivar, value|
          next if registry.ivars[entry.side][ivar]

          rule = prepass_rule(value, entry.side, registry)
          if rule
            registry.ivars[entry.side][ivar] = rule
            changed = true
          end
        end
        entry.writer_calls.each do |name, value|
          side = writer_side(name, entry.side, attrs)
          next unless side
          next if registry.ivars[side][:"@#{name}"]

          rule = prepass_rule(value, entry.side, registry)
          if rule
            registry.ivars[side][:"@#{name}"] = rule
            changed = true
          end
        end
        changed
      end

      # A writer call taints the ivar behind the attr on the side
      # that declares it, wherever the call sits.
      def writer_side(name, caller_side, attrs)
        %i[instance singleton]
          .sort_by { |side| (side == caller_side) ? 0 : 1 }
          .find { |side| attrs[side][:writer].include?(name) }
      end

      def return_rule(expr, side, registry)
        case expr
        when Prism::InstanceVariableWriteNode,
             Prism::InstanceVariableOrWriteNode
          prepass_rule(expr.value, side, registry)
        else
          prepass_rule(expr, side, registry)
        end
      end

      # The pre-pass mirror of visit_call's taint sources, over
      # syntax alone: a chain is tainted when its root is a
      # flagged constant, a tainted ivar, or a call to a method
      # the registry already holds.
      def prepass_rule(node, side, registry)
        case node
        when Prism::InstanceVariableReadNode
          registry.ivars[side][node.name]
        when Prism::CallNode
          if CORE_METHODS.include?(node.name)
            return nil unless CHAIN_METHODS.include?(node.name)

            return prepass_rule(node.receiver, side, registry)
          end
          return nil if node.name.end_with?("?")

          if t_call?(node, :let) || t_call?(node, :cast)
            args = node.arguments&.arguments
            return (args && args.size >= 2) ? type_rule(args[1]) : nil
          end
          prepass_receiver_rule(node, side, registry)
        end
      end

      def prepass_receiver_rule(node, side, registry)
        case (receiver = node.receiver)
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          receiver_rule(receiver) ||
            (registry.methods[:singleton][node.name] if
              names_class?(receiver, registry.class_name))
        when Prism::CallNode
          if receiver.name == :class &&
              receiver.receiver.is_a?(Prism::SelfNode)
            registry.methods[:singleton][node.name]
          else
            prepass_rule(receiver, side, registry)
          end
        when nil, Prism::SelfNode
          registry.methods[side][node.name]
        when Prism::InstanceVariableReadNode
          registry.ivars[side][receiver.name]
        end
      end

      # The class's own name in receiver position reaches its
      # singleton: the full path, or the trailing segments an
      # inner reference would use.
      def names_class?(receiver, class_name)
        path = receiver.location.slice.delete_prefix("::")
        path == class_name || class_name.end_with?("::#{path}") ||
          path == class_name.split("::").last
      end

      # Returns the matched rule so the caller can taint the
      # call's block even when the return value stays clean.
      def visit_call(node, tainted, ivars, scan)
        if CORE_METHODS.include?(node.name)
          return chain_through(node, tainted, ivars, scan)
        end

        if (rule = receiver_rule(node.receiver))
          scan.findings << finding_for(rule, node, scan.path)
          scan.producers[node.object_id] = rule
        elsif (rule = annotation_rule(node, scan))
          scan.producers[node.object_id] = rule
        elsif (rule = taint_source(node, tainted, ivars, scan))
          scan.findings << derived_finding(rule, node, scan.path)
          # A predicate returns a plain boolean and ends the
          # chain; anything else is presumed to still live in the
          # extension.
          unless node.name.end_with?("?")
            scan.producers[node.object_id] = rule
          end
          rule
        elsif (rule = registry_rule(node))
          scan.producers[node.object_id] = rule
        elsif (rule = self_call_rule(node))
          scan.findings << derived_finding(rule, node, scan.path)
          unless node.name.end_with?("?")
            scan.producers[node.object_id] = rule
          end
          rule
        end
      end

      # Inside a reopened bound class, self is the extension's
      # own object: a self-call the body does not define lands in
      # the extension, and so does a bare argumentless call that
      # is not plain Ruby.
      def self_call_rule(node)
        return nil unless @self_rule

        if node.receiver.is_a?(Prism::SelfNode)
          return nil if @self_defs.include?(node.name)

          @self_rule
        elsif node.receiver.nil? && node.arguments.nil? && !node.block
          return nil if @self_defs.include?(node.name) ||
            RUBY_METHODS.include?(node.name)

          @self_rule
        end
      end

      def chain_through(node, tainted, ivars, scan)
        return unless CHAIN_METHODS.include?(node.name)

        rule = taint_source(node, tainted, ivars, scan) ||
          receiver_rule(node.receiver)
        scan.producers[node.object_id] = rule if rule
      end

      # Calls to methods the pre-pass proved to hand out extension
      # values produce taint but no finding of their own: the
      # finding lands where the value is used.
      def registry_rule(node)
        return nil unless @registry

        case (receiver = node.receiver)
        when nil, Prism::SelfNode
          method_rule(@singleton ? :singleton : :instance, node.name)
        when Prism::CallNode
          if receiver.name == :class &&
              receiver.receiver.is_a?(Prism::SelfNode)
            method_rule(:singleton, node.name)
          end
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          if names_class?(receiver, @registry.class_name)
            method_rule(:singleton, node.name)
          end
        end
      end

      def method_rule(side, name)
        @registry.methods[side][name] ||
          @return_taints[[seed_scope, side, name]]
      end

      def taint_source(node, tainted, ivars, scan)
        case (receiver = node.receiver)
        when Prism::LocalVariableReadNode
          tainted[receiver.name]
        when Prism::InstanceVariableReadNode
          ivars[receiver.name]
        when Prism::CallNode
          scan.producers[receiver.object_id]
        end
      end

      # T.let and T.cast assert the value's type: a type under a
      # flagged namespace taints, any other constant type clears
      # whatever the value expression suggested.
      def annotation_rule(node, scan)
        return nil unless t_call?(node, :let) || t_call?(node, :cast)

        args = node.arguments&.arguments
        return nil unless args && args.size >= 2

        rule = type_rule(args[1])
        return rule if rule

        constant_type?(args[1]) ? nil : scan.producers[args[0].object_id]
      end

      def constant_type?(node)
        node.is_a?(Prism::ConstantReadNode) ||
          node.is_a?(Prism::ConstantPathNode)
      end

      def sig_node?(node)
        node.is_a?(Prism::CallNode) && node.name == :sig && node.block
      end

      # Params typed with a constant under a flagged namespace seed
      # the def's taint scope.
      def sig_taints(sig)
        params = sig_chain_call(sig, :params)
        args = params&.arguments&.arguments
        return {} unless args

        taints = {}
        args.grep(Prism::KeywordHashNode).each do |kw|
          kw.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode) &&
              assoc.key.is_a?(Prism::SymbolNode)

            rule = type_rule(assoc.value)
            taints[assoc.key.unescaped.to_sym] = rule if rule
          end
        end
        taints
      end

      # Param names the sig types with a constant outside every
      # flagged namespace: proven plain, immune to seeding.
      def plain_params(sig)
        params = sig_chain_call(sig, :params)
        args = params&.arguments&.arguments
        return EMPTY_SET unless args

        plain = Set.new
        args.grep(Prism::KeywordHashNode).each do |kw|
          kw.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode) &&
              assoc.key.is_a?(Prism::SymbolNode)
            next unless plain_type?(assoc.value)

            plain << assoc.key.unescaped.to_sym
          end
        end
        plain
      end

      # A bare unflagged constant, T.nilable of one, or a T::
      # container holding only such constants; T.untyped inside
      # a container keeps the erasure.
      def plain_type?(node)
        case node
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          source_rule(node.location.slice).nil?
        when Prism::CallNode
          args = node.arguments&.arguments
          if t_call?(node, :nilable)
            args&.size == 1 && plain_type?(args.first)
          elsif t_container?(node)
            !args.nil? && args.all? { |arg| plain_type?(arg) }
          else
            false
          end
        else
          false
        end
      end

      def t_container?(node)
        return false unless node.name == :[] &&
          constant_type?(node.receiver)

        node.receiver.location.slice.delete_prefix("::")
          .start_with?("T::")
      end

      def sig_chain_call(sig, name)
        body = sig.block.body
        node = body.is_a?(Prism::StatementsNode) ? body.body.first : body
        while node.is_a?(Prism::CallNode)
          return node if node.name == name

          node = node.receiver
        end
        nil
      end

      def type_rule(node)
        case node
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          source_rule(node.location.slice)
        when Prism::CallNode
          args = node.arguments&.arguments
          if t_call?(node, :nilable) && args&.size == 1
            type_rule(args.first)
          end
        end
      end

      def t_call?(node, name)
        node.name == name &&
          node.receiver.is_a?(Prism::ConstantReadNode) &&
          node.receiver.name == :T
      end

      def index_rules
        @rule_index = @rules.to_h { |rule| [rule.namespace, rule] }
      end

      # Cumulative :: prefixes of the path against the namespace
      # index, shortest first, tried under each level of the given
      # nesting before the path as written—flat cost however
      # many classes the tree promotes to rules.
      def namespace_rule(path, nesting = EMPTY_NESTING)
        segments = path.split("::")
        nesting.size.downto(1) do |depth|
          rule = prefix_rule(nesting.first(depth), segments)
          return rule if rule
        end
        prefix_rule(EMPTY_NESTING, segments)
      end

      def prefix_rule(base, segments)
        prefix = base.empty? ? nil : base.join("::")
        segments.each do |seg|
          prefix = prefix ? "#{prefix}::#{seg}" : seg
          rule = @rule_index[prefix]
          return rule if rule
        end
        nil
      end

      # An anchored path resolves from the root; anything else the
      # way Ruby would look it up, innermost scope first.
      def source_rule(slice)
        if slice.start_with?("::")
          namespace_rule(slice.delete_prefix("::"))
        else
          namespace_rule(slice, @nesting)
        end
      end

      def receiver_rule(receiver)
        return nil unless constant_type?(receiver)

        source_rule(receiver.location.slice)
      end

      def finding_for(rule, node, path)
        interp = {
          method: node.name, gem: rule.gem,
          receiver: node.receiver.location.slice.delete_prefix("::")
        }
        message = rule.verified ? MESSAGE : UNVERIFIED_MESSAGE
        # In a chained call the node spans its whole receiver;
        # the method-name line is where the reader looks.
        location = node.message_loc || node.location
        Finding.new(
          check: CHECK,
          severity: :warning,
          message: format(message, interp),
          why: format(rule.verified ? UNSAFE_WHY : UNVERIFIED_WHY, interp),
          fix: format(FIX, interp),
          path: path,
          line: location.start_line,
          source: node.location.slice.lines.first&.strip
        )
      end

      def derived_finding(rule, node, path)
        interp = {method: node.name, gem: rule.gem}
        location = node.message_loc || node.location
        Finding.new(
          check: CHECK,
          severity: :warning,
          message: format(DERIVED_MESSAGE, interp),
          why: format(rule.verified ? UNSAFE_WHY : UNVERIFIED_WHY, interp),
          fix: format(FIX, interp),
          path: path,
          line: location.start_line,
          source: node.location.slice.lines.first&.strip
        )
      end
    end
  end
end
