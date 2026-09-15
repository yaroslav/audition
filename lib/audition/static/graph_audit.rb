# frozen_string_literal: true

require "rubydex"
require_relative "../rewriters"
require_relative "work_split"

module Audition
  module Static
    # Whole-program semantic checks backed by the rubydex graph.
    # rubydex resolves state to its true owner, so an ivar written in
    # the class body, in `def self.x`, and inside `class << self`,
    # across several files, unifies into one declaration owned by the
    # singleton class. Per-file AST visitors cannot see that.
    class GraphAudit
      CVAR_WHY =
        "Class variables cannot be accessed from non-main Ractors " \
        "at all; both reads and writes raise " \
        "Ractor::IsolationError (\"can not access class variables " \
        "from non-main Ractors\")."
      CVAR_FIX =
        "Replace with a deeply frozen constant, per-instance " \
        "state, or Ractor-local storage (Ractor.current[:key], " \
        "Ractor.store_if_absent)."
      STATE_WHY =
        "This instance variable lives on the class/module object, " \
        "which is shared across Ractors; non-main Ractors raise " \
        "Ractor::IsolationError when writing it, and when reading " \
        "it while it holds a non-shareable value (verified on " \
        "Ruby 4.0)."
      STATE_FIX =
        "Precompute and freeze the value at load time: a memo " \
        "that needs no configuration becomes a frozen private " \
        "constant (EMPTY = new(nil, nil).freeze), a cheap " \
        "derivation drops its memo altogether, and " \
        "per-subclass values compute in the inherited hook " \
        "(guard on subclass.name for anonymous classes). For " \
        "collections, rebuild and refreeze on write, " \
        "copy-on-write: self.list = " \
        "(list + [item]).freeze; never mutate in place. As a " \
        "last resort use Ractor.store_if_absent for " \
        "per-Ractor state, or read the ivar first and proxy " \
        "the write to the main Ractor."
      FROZEN_MEMO_WHY =
        "Every write memoizes a shareable (frozen) value, so " \
        "non-main Ractors can read it once it has been " \
        "computed; only the first write must happen on the " \
        "main Ractor, or it raises Ractor::IsolationError."
      FROZEN_MEMO_FIX =
        "Warm the cache at boot, before spawning Ractors: call " \
        "the memoizing method from an initializer, an on_load " \
        "hook, an eager_load! override, or the inherited hook. " \
        "A value that can be nil or false never sticks under " \
        "||=, so guard it with defined? instead. If the value " \
        "genuinely must be computed at runtime, read the ivar " \
        "first and proxy only the write to the main Ractor, or " \
        "use Ractor.store_if_absent."
      BEST_EFFORT_WHY =
        "Writes wrap their value in Ractor.make_shareable with " \
        "a rescue fallback: shareable values are deeply frozen " \
        "and readable from any Ractor, while unshareable values " \
        "keep their old (Ractor-hostile) behavior. Whether this " \
        "state is actually safe depends on what the application " \
        "assigns; the dynamic probe reports ground truth."
      BEST_EFFORT_FIX =
        "Assign only shareable values (strings, symbols, frozen " \
        "containers) before spawning Ractors. Configuration " \
        "that cannot be shareable needs per-Ractor state or a " \
        "main-Ractor proxy instead."
      DERIVED_WHY =
        "The value comes from another constant whose own " \
        "definition is already flagged: freezing this one is " \
        "shallow and does not change what the referent holds, " \
        "so a non-main Ractor reading it can raise the same " \
        "Ractor::IsolationError."
      DERIVED_FIX =
        "Make the referenced constant deeply shareable first; " \
        "this finding follows its verdict."
      CONTAINED_WHY =
        "The assigned expression is flagged on this same line: " \
        "the constant holds whatever unshareable value that " \
        "expression produces, so a non-main Ractor reading the " \
        "constant hits the same problem."
      SINGLETON_SCAN_WHY =
        "The receiver is a runtime value, so the graph cannot " \
        "attribute the state this body writes to any class. If " \
        "the receiver is one, these are class-level instance " \
        "variables and a non-main Ractor raises " \
        "Ractor::IsolationError writing them."
      SINGLETON_SCAN_FIX =
        "Open the singleton on the constant itself so the state " \
        "resolves, or confirm the receiver with the dynamic " \
        "probe, which reads the live object graph."
      ANCESTOR_SCAN_WHY =
        "The ancestor is a runtime value, so whatever it " \
        "contributes—class-level state, class variables, " \
        "hostile APIs—is invisible here. A clean report for " \
        "this class covers only what the class itself declares."
      ANCESTOR_SCAN_FIX =
        "Name the superclass or module directly where the " \
        "hierarchy is static. Where it cannot be, audit the " \
        "candidates separately; the dynamic probe sweeps the " \
        "ancestors that are actually in play."
      CONSTANT_SCAN_WHY =
        "The path starts from a runtime value, so the constant " \
        "this assignment defines holds something the shareability " \
        "checks never saw."
      CONSTANT_SCAN_FIX =
        "Reference the constant by its static path, or let the " \
        "dynamic probe check the value with Ractor.shareable?."

      # Findings from these per-file checks seed the derived-
      # constant propagation.
      PROPAGATED_CHECKS = [
        "mutable-constants", "unshareable-reads", "native-gem-calls"
      ].freeze

      # Checks that flag an expression rather than the constant
      # it may be assigned to; when such a finding sits inside a
      # constant assignment, the constant inherits it by name.
      EXPRESSION_CHECKS =
        ["unshareable-reads", "native-gem-calls"].freeze

      # The expressions rubydex reports as unresolvable. Each is a
      # hole in the walks above, so where the shape could hide
      # something they look for, the hole is reported. rubydex's
      # parse rules are left out—the per-file syntax check already
      # reports those—as are its visibility rules, which say
      # nothing about Ractors.
      SCAN_RULES = {
        "DynamicSingletonDefinition" => :singleton,
        "DynamicAncestor" => :ancestor,
        "DynamicConstantReference" => :constant
      }.freeze

      MIXINS = ["include", "extend", "prepend"].freeze

      STATE_WRITES = [
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableOperatorWriteNode,
        Prism::ClassVariableWriteNode,
        Prism::ClassVariableOrWriteNode,
        Prism::ClassVariableAndWriteNode,
        Prism::ClassVariableOperatorWriteNode
      ].freeze

      # @param sources [Hash{String => String}] path => source
      # @param constant_findings [Array<Finding>] per-file findings
      #   whose definition sites seed derived-constant propagation
      # @param progress [Progress]
      # @return [Array<Finding>]
      def analyze_sources(sources, constant_findings: [],
        workers: nil, progress: Progress::SILENT)
        graph = Rubydex::Graph.new
        progress.stage("indexing", total: sources.size)
        sources.each do |path, code|
          progress.tick
          graph.index_source(path, code, "ruby")
        end
        @sources = sources
        @workers = workers
        @frozen_memos = frozen_memo_map(sources)
        @reported_lines = constant_findings
          .map { |f| [f.path, f.line] }.to_set
        @constant_findings = constant_findings.select do |f|
          PROPAGATED_CHECKS.include?(f.check)
        end
        audit(graph, progress)
      end

      # rubydex's index_all descends directories but skips bare file
      # lists, so files are fed through index_source individually.
      #
      # @param paths [Array<String>] files to index and audit
      # @param constant_findings [Array<Finding>] see
      #   {#analyze_sources}
      # @param progress [Progress]
      # @return [Array<Finding>]
      def analyze_paths(paths, constant_findings: [], workers: nil,
        progress: Progress::SILENT)
        sources = {}
        progress.stage("reading", total: paths.size)
        paths.each do |path|
          progress.tick
          sources[path] = File.read(path)
        rescue SystemCallError
          next
        end
        analyze_sources(sources, constant_findings: constant_findings,
          workers: workers, progress: progress)
      end

      # Names one slice of a scan declares, for a parallel audit to
      # merge before any walk emits.
      #
      # @api private
      # @param sources [Hash{String => String}] path => source
      # @return [Hash{Symbol => Object}]
      def gathered_names(sources)
        @sources = sources
        {writers: declared_writers, declared: declared_names,
         extended: extended_names}
      end

      # The class-state walks over one slice, against names
      # gathered from the whole scan.
      #
      # @api private
      # @param sources [Hash{String => String}] path => source
      # @param seen [Set] path/line pairs a declaration claimed
      # @param names [Hash] from {#gathered_names}, merged
      # @return [Array<Array<Finding>>] one batch per walk
      def walk_batches(sources, seen, names)
        @sources = sources
        [singleton_attr_findings,
          extended_module_findings(seen, names[:extended]),
          dynamic_ivar_findings(seen, names[:declared]),
          attribute_write_findings(seen, names[:writers])]
      end

      private

      # Resolution is one opaque call inside rubydex; everything
      # after it walks declarations rather than files, so the stage
      # names say which pass a waiting reader is watching.
      def audit(graph, progress = Progress::SILENT)
        progress.stage("resolving")
        graph.resolve
        findings = []
        declarations = graph.declarations
        progress.stage("declarations", total: declarations.size)
        declarations.each do |decl|
          progress.tick
          case decl
          when Rubydex::ClassVariable
            findings.concat(class_variable_findings(decl))
          when Rubydex::InstanceVariable
            findings.concat(class_state_findings(decl))
          end
        end
        seen = findings.map { |f| [f.path, f.line] }.to_set
        class_state_batches(seen, progress).each do |batch|
          findings.concat(batch)
          batch.each { |f| seen << [f.path, f.line] }
        end
        progress.stage("constants")
        findings.concat(derived_constant_findings(graph))
        progress.stage("diagnostics")
        findings.concat(static_scan_findings(graph, findings))
        findings.sort_by { |f| [f.path, f.line] }
      end

      # rubydex says which expressions it could not resolve; this
      # turns the ones that matter into findings, so a blind spot
      # reads as a blind spot rather than as a clean line. A
      # diagnostic is dropped where something else already reported
      # that line, and where the shape cannot hide what the walks
      # look for.
      def static_scan_findings(graph, found)
        reported = @reported_lines +
          found.map { |f| [f.path, f.line] }
        seen = Set.new
        graph.diagnostics.filter_map do |diagnostic|
          kind = SCAN_RULES[diagnostic.rule.rule_name]
          next unless kind

          path = path_from_uri(diagnostic.location.uri)
          line = diagnostic.location.start_line + 1
          next unless seen.add?([path, line, kind])
          next if reported.include?([path, line])

          scan_finding(kind, path, line)
        end
      end

      def scan_finding(kind, path, line)
        root = diagnostic_root(path)
        return nil unless root

        case kind
        when :singleton then singleton_scan(root, path, line)
        when :ancestor then ancestor_scan(root, path, line)
        else constant_scan(root, path, line)
        end
      end

      # Only the files a diagnostic points at are parsed here. The
      # walks may have run in Ractors, whose trees never reach this
      # one, and the shapes are rare enough that re-reading the
      # whole tree would cost more than the checks on it.
      def diagnostic_root(path)
        @diagnostic_roots ||= {}
        return @diagnostic_roots[path] if @diagnostic_roots.key?(path)

        code = @sources[path]
        file = code && SourceFile.new(source: code, path: path)
        @diagnostic_roots[path] = file&.valid_syntax? ? file.root : nil
      end

      # A runtime singleton target only matters when the body it
      # opens writes state: that is what the graph could not
      # attribute to a class.
      def singleton_scan(root, path, line)
        node = node_at(root, line) do |candidate|
          candidate.is_a?(Prism::SingletonClassNode) ||
            (candidate.is_a?(Prism::DefNode) && candidate.receiver)
        end
        return nil unless node && state_writes?(node)

        scan(path, line, severity: :warning,
          message: "class-level state behind an unresolved " \
                   "singleton receiver",
          why: SINGLETON_SCAN_WHY, fix: SINGLETON_SCAN_FIX)
      end

      # A runtime superclass always defines a class. A runtime
      # mixin argument only names an ancestor inside a class or
      # module body: a matcher called `include` in a test reads the
      # same way to the graph and has to stay silent.
      def ancestor_scan(root, path, line)
        klass = node_at(root, line) do |candidate|
          candidate.is_a?(Prism::ClassNode) && candidate.superclass &&
            constant_slice(candidate.superclass).nil?
        end
        mixin = klass ? nil : body_mixins(path, root)[line]
        return nil unless klass || mixin

        subject =
          if klass
            "superclass of #{klass.constant_path.slice}"
          else
            "#{mixin[0]} argument in #{mixin[1]}"
          end
        scan(path, line, severity: :warning,
          message: "unresolved #{subject}",
          why: ANCESTOR_SCAN_WHY, fix: ANCESTOR_SCAN_FIX)
      end

      # A runtime constant path only matters where it defines a
      # constant: elsewhere there is no name whose shareability
      # anything would have checked.
      def constant_scan(root, path, line)
        name = constant_assigned_at(root, line)
        return nil unless name

        scan(path, line, severity: :info,
          message: "unresolved constant path in #{name}",
          why: CONSTANT_SCAN_WHY, fix: CONSTANT_SCAN_FIX)
      end

      def scan(path, line, severity:, message:, why:, fix:)
        Finding.new(
          check: "static-scan",
          severity: severity,
          message: message,
          why: why,
          fix: fix,
          path: path,
          line: line,
          source: source_line(path, line)
        )
      end

      def node_at(root, line)
        queue = [root]
        until queue.empty?
          node = queue.shift
          if node.location.start_line == line && yield(node)
            return node
          end

          queue.concat(node.compact_child_nodes)
        end
        nil
      end

      # Nested classes and modules are skipped: their state is
      # their own, and the graph resolves it.
      def state_writes?(node)
        queue = node.compact_child_nodes
        until queue.empty?
          child = queue.shift
          return true if STATE_WRITES.include?(child.class)
          next if child.is_a?(Prism::ClassNode) ||
            child.is_a?(Prism::ModuleNode)

          queue.concat(child.compact_child_nodes)
        end
        false
      end

      def body_mixins(path, root)
        @body_mixins ||= {}
        @body_mixins[path] ||= collect_body_mixins(root)
      end

      # Method and block bodies are skipped: a receiverless call in
      # one is not a mixin into the enclosing class.
      def collect_body_mixins(root)
        found = {}
        queue = root.compact_child_nodes.map { |node| [node, nil] }
        until queue.empty?
          node, owner = queue.shift
          case node
          when Prism::ClassNode, Prism::ModuleNode
            owner = node.constant_path.slice
          when Prism::DefNode, Prism::BlockNode, Prism::LambdaNode
            next
          when Prism::CallNode
            record_mixin(found, node, owner)
          end
          queue.concat(
            node.compact_child_nodes.map { |child| [child, owner] }
          )
        end
        found
      end

      # Keyed by every line the call spans, since the diagnostic
      # points at the argument rather than the call.
      def record_mixin(found, node, owner)
        return unless owner && node.receiver.nil? &&
          MIXINS.include?(node.name.to_s)
        return if resolved_mixin?(node)

        location = node.location
        (location.start_line..location.end_line).each do |line|
          found[line] ||= [node.name.to_s, owner]
        end
      end

      # The graph gave up on the line, but if every argument
      # names a constant the walks read it anyway, and saying
      # otherwise would contradict the finding they emit.
      def resolved_mixin?(node)
        arguments = Array(node.arguments&.arguments)
        arguments.any? &&
          arguments.all? { |arg| constant_slice(arg) }
      end

      def constant_assigned_at(root, line)
        queue = [root]
        until queue.empty?
          node = queue.shift
          location = node.location
          next unless line
            .between?(location.start_line, location.end_line)

          name = constant_target_name(node)
          return name if name

          queue.concat(node.compact_child_nodes)
        end
        nil
      end

      # The constant a node assigns, nil for anything else.
      def constant_target_name(node)
        case node
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode
          node.name.to_s
        when Prism::ConstantPathWriteNode,
             Prism::ConstantPathOrWriteNode
          node.target.location.slice
        end
      end

      # Below this many files the Ractor spawn and the copy of the
      # sources cost more than the walks they divide.
      PARALLEL_THRESHOLD = 100

      # Every batch is computed against the declaration findings
      # alone, so the dedup set only suppresses lines a declaration
      # already claimed. Each walks every parsed source once, which
      # is why they are named separately.
      def class_state_batches(seen, progress)
        workers = @workers || WorkSplit.workers
        if @sources.size < PARALLEL_THRESHOLD || workers <= 1
          serial_batches(seen, progress)
        else
          parallel_batches(seen, progress, workers)
        end
      rescue Ractor::Error, Ractor::ClosedError => e
        # The silent fallback would otherwise mask a walk that is
        # itself Ractor-hostile; surface it under -w. ClosedError
        # is not a Ractor::Error: it is what sending to a worker
        # that already died raises.
        if $VERBOSE
          warn "Audition: parallel graph audit fell back to " \
               "serial: #{e.class}: #{e.message}"
        end
        progress.ractors = nil
        serial_batches(seen, progress)
      end

      def serial_batches(seen, progress)
        progress.stage("parsing", total: @sources.size)
        source_roots(progress)
        progress.stage("singletons")
        singletons = singleton_attr_findings
        progress.stage("extends")
        extended = extended_module_findings(seen)
        progress.stage("ivars")
        ivars = dynamic_ivar_findings(seen)
        progress.stage("writers")
        [singletons, extended, ivars,
          attribute_write_findings(seen)]
      end

      # A walk may only emit once every name the whole scan
      # declares is known, so the workers run in two rounds: gather
      # the names of a slice, then walk it against the merged set.
      # Parsed trees cannot cross a Ractor boundary, so the workers
      # stay alive between the rounds and keep theirs.
      def parallel_batches(seen, progress, workers)
        experimental = Warning[:experimental]
        Warning[:experimental] = false
        port = Ractor::Port.new
        chunks = chunks_for(workers)
        progress.ractors = chunks.size
        progress.stage("parsing")
        ractors = chunks.map { |paths| worker(paths, port) }
        names = merge_names(gather(port, ractors))
        progress.stage("state")
        claimed = seen.to_a
        ractors.each { |ractor| ractor.send([claimed, names]) }
        collect_batches(ractors)
      ensure
        Warning[:experimental] = experimental
      end

      def chunks_for(workers)
        WorkSplit.chunks(
          @sources.map { |path, code| [path, code.bytesize] }, workers
        )
      end

      def worker(paths, port)
        Ractor.new(slice(paths), port) do |sources, out|
          audit = GraphAudit.new
          begin
            names = audit.gathered_names(sources)
          ensure
            # Sent from `ensure` so a gather that raises still
            # releases the main Ractor; `Ractor#value` reports why.
            out.send(names)
          end
          # Ruby cannot copy a Set whose elements are compound, so
          # the claimed lines travel as pairs.
          claimed, gathered = Ractor.receive
          audit.walk_batches(sources, claimed.to_set, gathered)
        end
      end

      def gather(port, ractors)
        parts = ractors.map { port.receive }
        # nil stands in for a worker that died gathering; asking
        # for its value raises what killed it.
        ractors.each(&:value) if parts.any?(&:nil?)
        parts
      end

      # Each worker returns one batch per walk, in the order
      # {#serial_batches} runs them; the batches concatenate walk
      # by walk so the dedup a batch carries still holds.
      def collect_batches(ractors)
        ractors.map(&:value).transpose.map { |batch| batch.flatten(1) }
      end

      def slice(paths)
        paths.to_h { |path| [path, @sources[path]] }
      end

      def merge_names(parts)
        merged = {writers: {}, declared: Set.new, extended: Set.new}
        parts.each do |part|
          part[:writers].each do |owner, ivars|
            (merged[:writers][owner] ||= Set.new).merge(ivars)
          end
          merged[:declared].merge(part[:declared])
          merged[:extended].merge(part[:extended])
        end
        merged
      end

      # A constant defined from another constant—an alias
      # (`DEFAULT = PRIMARY`) or a frozen container of references
      # (`ALL = [A, B].freeze`)—inherits the referent's problem,
      # which the per-file classifier cannot see. The graph knows
      # every reference, so flagged definitions propagate to any
      # constant assignment that references them, transitively.
      def derived_constant_findings(graph)
        flagged = {}
        @constant_findings.each do |f|
          flagged[[f.path, f.line]] ||= f
        end
        return [] if flagged.empty?

        spans = assignment_spans
        by_site = constant_declarations_by_site(graph)
        results = []
        queue = flagged.keys.flat_map { |site| by_site[site] }.uniq
        contained_findings(spans, flagged, results) do |site|
          queue.concat(by_site[site])
        end
        until queue.empty?
          decl = queue.shift
          source = flagged_source(decl, flagged)
          next unless source

          decl.references.each do |ref|
            path = path_from_uri(ref.location.uri)
            line = ref.location.start_line + 1
            span = spans[path].find { |s| s[:lines].cover?(line) }
            next unless span

            site = [path, span[:line]]
            next if flagged.key?(site)

            finding = Finding.new(
              check: "derived-constants",
              severity: source.severity,
              message: "constant #{span[:name]} references " \
                       "#{decl.name}, itself flagged",
              why: DERIVED_WHY,
              fix: DERIVED_FIX,
              path: path,
              line: span[:line],
              source: source_line(path, span[:line])
            )
            flagged[site] = finding
            results << finding
            queue.concat(by_site[site])
          end
        end
        results
      end

      # An expression-check finding inside a constant assignment
      # marks the constant itself: the assignment captures the
      # flagged value under a name the graph can then follow.
      def contained_findings(spans, flagged, results)
        emitted = Set.new
        flagged.to_a.each do |(path, line), seed|
          next unless EXPRESSION_CHECKS.include?(seed.check)

          span = spans[path].find { |s| s[:lines].cover?(line) }
          next unless span

          site = [path, span[:line]]
          next unless emitted.add?(site)

          already = flagged[site]
          next if already && !EXPRESSION_CHECKS.include?(already.check)

          finding = Finding.new(
            check: "derived-constants",
            severity: seed.severity,
            message: "constant #{span[:name]} is assigned a " \
                     "value flagged on this line",
            why: CONTAINED_WHY,
            fix: DERIVED_FIX,
            path: path,
            line: span[:line],
            source: source_line(path, span[:line])
          )
          flagged[site] ||= finding
          results << finding
          yield site
        end
      end

      def constant_declarations_by_site(graph)
        by_site = Hash.new { |h, k| h[k] = [] }
        graph.declarations.each do |decl|
          next unless constant_declaration?(decl)

          each_local_definition(decl).each do |defn|
            site = [path_from_uri(defn.location.uri),
              defn.location.start_line + 1]
            by_site[site] << decl
          end
        end
        by_site
      end

      # rubydex leaves a declaration as a Todo when some reference
      # keeps it from settling on a type. One with a constant name
      # still carries definitions and references, and propagation
      # already requires a flagged definition site plus references
      # inside constant assignments, so it qualifies.
      def constant_declaration?(decl)
        case decl
        when Rubydex::Constant, Rubydex::ConstantAlias
          true
        when Rubydex::Todo
          decl.name.split("::").last&.match?(/\A[A-Z]/) || false
        else
          false
        end
      end

      def flagged_source(decl, flagged)
        each_local_definition(decl).filter_map do |defn|
          flagged[[path_from_uri(defn.location.uri),
            defn.location.start_line + 1]]
        end.first
      end

      # Line spans of every constant assignment, so a reference
      # landing inside one attributes to the constant it defines.
      def assignment_spans
        spans = Hash.new { |h, k| h[k] = [] }
        @sources.each do |path, code|
          file = SourceFile.new(source: code, path: path)
          next unless file.valid_syntax?

          queue = [file.root]
          until queue.empty?
            node = queue.shift
            queue.concat(node.child_nodes.compact)
            name = constant_target_name(node)
            next unless name

            location = node.location
            spans[path] << {
              lines: (location.start_line..location.end_line),
              line: location.start_line,
              name: name
            }
          end
        end
        spans
      end

      def class_variable_findings(decl)
        variable = decl.name.split("#").last
        owner = display_owner(decl.owner)
        each_local_definition(decl).map do |defn|
          finding_at(
            defn,
            check: "class-variables",
            message: "class variable #{variable} on #{owner}",
            why: CVAR_WHY,
            fix: CVAR_FIX
          )
        end
      end

      def class_state_findings(decl)
        return [] unless decl.owner.is_a?(Rubydex::SingletonClass)

        variable = decl.name.split("#").last
        owner = display_owner(decl.owner)
        verdict = @frozen_memos["#{owner}/#{variable}"]
        each_local_definition(decl).map do |defn|
          case verdict
          when :frozen
            finding_at(
              defn,
              check: "class-level-state",
              severity: :info,
              message: "frozen memoization #{variable} on " \
                       "#{owner}; warm it on the main Ractor",
              why: FROZEN_MEMO_WHY,
              fix: FROZEN_MEMO_FIX
            )
          when :best_effort
            finding_at(
              defn,
              check: "class-level-state",
              severity: :warning,
              message: "best-effort frozen state #{variable} " \
                       "on #{owner}",
              why: BEST_EFFORT_WHY,
              fix: BEST_EFFORT_FIX
            )
          else
            finding_at(
              defn,
              check: "class-level-state",
              message: "class-level instance variable " \
                       "#{variable} on #{owner}",
              why: STATE_WHY,
              fix: STATE_FIX
            )
          end
        end
      end

      # Parsed once: the passes below all walk every file.
      def source_roots(progress = Progress::SILENT)
        @source_roots ||= @sources.filter_map do |path, code|
          progress.tick
          file = SourceFile.new(source: code, path: path)
          [path, file.root] if file.valid_syntax?
        end.to_h
      end

      # An attribute writer on a singleton class declares
      # class-level state the same way an assignment does, but
      # no line assigns the ivar, so the graph never sees it.
      # A reader alone is left to the graph: whatever writes
      # the ivar is already a declaration.
      SINGLETON_ATTRS = ["attr_accessor", "attr_writer"].freeze

      def singleton_attr_findings
        singleton_attrs.flat_map do |path, attrs|
          attrs.map do |owner, ivar, line|
            Finding.new(
              check: "class-level-state",
              severity: :error,
              message: "class-level instance variable " \
                       "@#{ivar} on #{owner}",
              why: STATE_WHY,
              fix: STATE_FIX,
              path: path,
              line: line,
              source: source_line(path, line)
            )
          end
        end
      end

      def singleton_attrs
        @singleton_attrs ||= source_roots.to_h do |path, root|
          attrs = []
          walk_singletons(root, [], attrs)
          [path, attrs]
        end
      end

      # Assigning a declared singleton attribute writes the
      # class-level instance variable behind it, which a non-main
      # Ractor cannot do at all. The declaration is flagged where
      # it sits; this is the assignment, which is a line of its
      # own. Readers are left out: a read raises only on an
      # unshareable value, and the declaration already says so.
      def attribute_write_findings(seen, writers = declared_writers)
        return [] if writers.empty?

        source_roots.flat_map do |path, root|
          calls = []
          collect_writes(root, writers, calls)
          calls.filter_map do |owner, name, line|
            next if seen.include?([path, line])

            Finding.new(
              check: "class-level-state",
              severity: :error,
              message: "class-level instance variable " \
                       "@#{name} on #{owner}",
              why: STATE_WHY,
              fix: STATE_FIX,
              path: path,
              line: line,
              source: source_line(path, line)
            )
          end
        end
      end

      # Attribute names by their owner's last segment: a write
      # site and the declaration rarely spell the path the same
      # way.
      def declared_writers
        writers = {}
        singleton_attrs.each_value do |attrs|
          attrs.each do |owner, ivar, _|
            key = owner.split("::").last
            (writers[key] ||= Set.new) << ivar
          end
        end
        writers
      end

      def collect_writes(node, writers, out)
        if node.is_a?(Prism::CallNode)
          name = node.name.to_s
          owner = name.end_with?("=") &&
            constant_slice(node.receiver)
          if owner && writers[owner.split("::").last]
              &.include?(name.chomp("="))
            out << [owner, name.chomp("="),
              node.location.start_line]
          end
        end
        node.compact_child_nodes.each do |child|
          collect_writes(child, writers, out)
        end
      end

      # Extending a module makes its instance methods run with
      # a class as self, so the ivars they assign live on that
      # class. Which class is not knowable from the module, so
      # the finding lands on the assignment.
      IVAR_WRITES = [
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableOperatorWriteNode
      ].freeze

      def extended_module_findings(seen, names = extended_names)
        return [] if names.empty?

        source_roots.flat_map do |path, root|
          writes = []
          walk_extended(root, [], names, nil, writes)
          writes.filter_map do |owner, ivar, line|
            next if seen.include?([path, line])

            Finding.new(
              check: "class-level-state",
              severity: :error,
              message: "class-level instance variable " \
                       "#{ivar} on #{owner}",
              why: STATE_WHY,
              fix: STATE_FIX,
              path: path,
              line: line,
              source: source_line(path, line)
            )
          end
        end
      end

      # Writing an instance variable through its name reaches
      # the same class-level state an assignment does, and the
      # graph indexes assignments only. Verified on Ruby 4.0:
      # set and remove always raise in a non-main Ractor, while
      # get raises only on an unshareable value, so it rides on
      # the declaration the way a plain read does.
      DYNAMIC_WRITES = Ractor.make_shareable(
        Set.new(%i[instance_variable_set remove_instance_variable])
      )

      # Ruby hands these hooks the class that triggered them.
      CLASS_HOOKS = Ractor.make_shareable(
        Set.new(%i[inherited included extended prepended])
      )

      def dynamic_ivar_findings(seen, declared = declared_names)
        source_roots.flat_map do |path, root|
          writes = []
          walk_dynamic(root, Context.new([], false, false, {}),
            declared, writes)
          writes.filter_map do |owner, ivar, line|
            next if seen.include?([path, line])

            Finding.new(
              check: "class-level-state",
              severity: :error,
              message: "class-level instance variable " \
                       "#{ivar} on #{owner}",
              why: STATE_WHY,
              fix: STATE_FIX,
              path: path,
              line: line,
              source: source_line(path, line)
            )
          end
        end
      end

      # Every class and module the target declares, by last name
      # segment: a receiver spelled one way at the call site and
      # another at the definition still names the same thing.
      def declared_names
        names = Set.new
        source_roots.each_value do |root|
          collect_declared(root, names)
        end
        names
      end

      def collect_declared(node, names)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          names << node.constant_path.slice.split("::").last
        end
        node.compact_child_nodes.each do |child|
          collect_declared(child, names)
        end
      end

      # nesting: enclosing class and module names.
      # singleton: whether self is a class or module here.
      # sclass: whether a bare def here defines a class method.
      # hooks: locals a class hook bound to a class.
      Context = Struct.new(:nesting, :singleton, :sclass, :hooks)

      def walk_dynamic(node, context, declared, out)
        context = descend_dynamic(node, context)
        if node.is_a?(Prism::CallNode)
          record_dynamic(node, context, declared, out)
        end
        node.compact_child_nodes.each do |child|
          walk_dynamic(child, context, declared, out)
        end
      end

      # A class body has the class as self, but a bare def in
      # one defines an instance method, where self is not. Only
      # a receiver or an enclosing singleton class makes it a
      # class method again.
      def descend_dynamic(node, context)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          Context.new(
            context.nesting + [node.constant_path.slice],
            true, false, {}
          )
        when Prism::SingletonClassNode
          Context.new(context.nesting, true, true, context.hooks)
        when Prism::DefNode
          singleton = !node.receiver.nil? || context.sclass
          Context.new(context.nesting, singleton, false,
            singleton ? hook_locals(node) : {})
        else
          context
        end
      end

      def hook_locals(node)
        return {} unless CLASS_HOOKS.include?(node.name)

        first = node.parameters&.requireds&.first
        return {} unless first.is_a?(Prism::RequiredParameterNode)

        {first.name => true}
      end

      def record_dynamic(node, context, declared, out)
        return unless DYNAMIC_WRITES.include?(node.name)

        name = node.arguments&.arguments&.first
        return unless name.is_a?(Prism::SymbolNode) &&
          name.unescaped.start_with?("@")

        owner = dynamic_owner(node.receiver, context, declared)
        return unless owner

        out << [owner, name.unescaped, node.location.start_line]
      end

      # Only receivers that are a class or module for certain:
      # self in a singleton, a constant the target declares, a
      # hook's class argument, or anything's own class.
      def dynamic_owner(receiver, context, declared)
        case receiver
        when nil, Prism::SelfNode
          context.nesting.last if context.singleton
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          name = constant_slice(receiver)
          name if declared.include?(name.split("::").last)
        when Prism::LocalVariableReadNode
          receiver.slice if context.hooks[receiver.name]
        when Prism::CallNode
          receiver.slice if receiver.name == :class
        end
      end

      # The name a concern gives the module it puts on the class.
      # Nothing in the concern's own source extends it: the mixin
      # that does lives in whatever library defines the pattern,
      # so within the target the name is the only evidence.
      CLASS_METHODS = "ClassMethods"

      # The same methods declared as a block, with no module in
      # the source to hang the name on: the concern synthesizes
      # one under the conventional name at load time.
      CLASS_METHODS_BLOCK = :class_methods

      # Mixing into a singleton class lands a module's instance
      # methods on the class, the way extend does.
      SINGLETON_MIXINS = Ractor.make_shareable(
        Set.new(%i[prepend include])
      )

      # A module reached through its last name segment: the
      # extend site and the definition rarely spell the path
      # the same way.
      def extended_names
        names = Set.new([CLASS_METHODS])
        source_roots.each_value { |root| collect_extends(root, names) }
        names
      end

      def collect_extends(node, names)
        if node.is_a?(Prism::CallNode) && extend_call?(node)
          Array(node.arguments&.arguments).each do |arg|
            name = constant_slice(arg)
            names << name.split("::").last if name
          end
        end
        node.compact_child_nodes.each { |c| collect_extends(c, names) }
      end

      def extend_call?(node)
        return true if node.name == :extend
        return false unless SINGLETON_MIXINS.include?(node.name)

        node.receiver.is_a?(Prism::CallNode) &&
          node.receiver.name == :singleton_class
      end

      def constant_slice(node)
        case node
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          node.slice.delete_prefix("::")
        when Prism::CallNode
          const_get_slice(node)
        end
      end

      # A constant fetched through `const_get` names it as
      # plainly as the constant does, and a concern resolving
      # its own companion module writes the extend that way.
      # Only on self: an explicit receiver picks the scope at
      # runtime, which is the blind spot the scan reports.
      def const_get_slice(node)
        return unless node.name == :const_get
        return unless node.receiver.nil? ||
          node.receiver.is_a?(Prism::SelfNode)

        argument = Array(node.arguments&.arguments).first
        case argument
        when Prism::SymbolNode, Prism::StringNode
          argument.unescaped
        end
      end

      # A def with a receiver writes the module's own state,
      # which the graph already owns; a nested class starts
      # its own instance side.
      def walk_extended(node, nesting, names, owner, out)
        case node
        when Prism::ModuleNode
          name = node.constant_path.slice
          nesting += [name]
          owner = nesting.join("::") if
            names.include?(name.split("::").last)
        when Prism::ClassNode
          nesting += [node.constant_path.slice]
          owner = nil
        when Prism::CallNode
          if node.block && node.name == CLASS_METHODS_BLOCK
            owner = (nesting + [CLASS_METHODS]).join("::")
          end
        when Prism::DefNode
          return if node.receiver
        else
          if owner && IVAR_WRITES.any? { |k| node.is_a?(k) }
            out << [owner, node.name.to_s, node.location.start_line]
          end
        end
        node.compact_child_nodes.each do |child|
          walk_extended(child, nesting, names, owner, out)
        end
      end

      # Tracks the lexical nesting so `class << self` resolves
      # to the class it sits in, and `class << Name` to that name.
      def walk_singletons(node, nesting, out)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          nesting += [node.constant_path.slice]
        when Prism::SingletonClassNode
          owner = singleton_owner(node, nesting)
          collect_attrs(node.body, owner, out) if owner
        end
        node.compact_child_nodes.each do |child|
          walk_singletons(child, nesting, out)
        end
      end

      def singleton_owner(node, nesting)
        case node.expression
        when Prism::SelfNode then nesting.last
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          node.expression.slice
        end
      end

      # Only the body's own statements count: a nested def or
      # block calling attr_accessor defines something else.
      def collect_attrs(body, owner, out)
        return unless body.is_a?(Prism::StatementsNode)

        body.body.each do |stmt|
          next unless stmt.is_a?(Prism::CallNode) &&
            stmt.receiver.nil? &&
            SINGLETON_ATTRS.include?(stmt.name.to_s)

          Array(stmt.arguments&.arguments).each do |arg|
            name = attr_name(arg)
            out << [owner, name, stmt.location.start_line] if name
          end
        end
      end

      def attr_name(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped
        end
      end

      def each_local_definition(decl)
        decl.definitions.reject do |defn|
          defn.location.uri.start_with?("rubydex:")
        end
      end

      def finding_at(defn, check:, message:, why:, fix:,
        severity: :error)
        path = path_from_uri(defn.location.uri)
        line = defn.location.start_line + 1
        Finding.new(
          check: check,
          severity: severity,
          message: message,
          why: why,
          fix: fix,
          path: path,
          line: line,
          source: source_line(path, line)
        )
      end

      # Frozen memoization: every
      # write to the ivar is a memo site (`@x ||=` or a defined?
      # guard) whose value is provably shareable, either a frozen
      # literal, an explicit `.freeze` or make_shareable call.
      # Such state is read-safe from any Ractor once warmed, so
      # the finding downgrades to an info note. Any stray write
      # or unproven value keeps the error. Keys are
      # "Owner::Path/@name"; a dirty verdict in any file wins.
      def frozen_memo_map(sources)
        map = {}
        sources.each do |path, code|
          file = SourceFile.new(source: code, path: path)
          next unless file.valid_syntax?

          collector = Rewriters::Memoization::SingletonIvars.new
          collector.visit(file.root)
          classifier = LiteralClassifier.new(
            frozen_string_literal: file.frozen_string_literal?
          )
          collector.groups.each do |(namespace, name), ops|
            key = "#{namespace}/#{name}"
            verdict = group_verdict(ops, classifier)
            map[key] = weaker_verdict(map[key], verdict)
          end
          mark_singleton_reopenings(file, map)
        end
        map
      end

      # `class << Foo` bodies write ivars on Foo's singleton
      # class outside the collector's `class << self` tracking;
      # any such write taints the group so a reopening in one
      # file can never be shadowed by a clean memo in another.
      def mark_singleton_reopenings(file, map)
        queue = [file.root]
        until queue.empty?
          node = queue.shift
          queue.concat(node.child_nodes.compact)
          next unless node.is_a?(Prism::SingletonClassNode)

          owner =
            case node.expression
            when Prism::ConstantReadNode
              node.expression.name.to_s
            when Prism::ConstantPathNode
              node.expression.location.slice
            end
          next unless owner

          ivar_names_in(node).each do |ivar|
            map["#{owner}/#{ivar}"] = :dirty
          end
        end
      end

      IVAR_NODES = [
        Prism::InstanceVariableReadNode,
        Prism::InstanceVariableWriteNode,
        Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableTargetNode
      ].freeze

      def ivar_names_in(node)
        names = []
        queue = [node]
        until queue.empty?
          current = queue.shift
          queue.concat(current.child_nodes.compact)
          if IVAR_NODES.any? { |type| current.is_a?(type) }
            names << current.name.to_s
          end
        end
        names.uniq
      end

      # Cross-file merge keeps the weakest promise: any dirty file
      # taints the group, and best-effort beats fully frozen.
      VERDICT_RANK = {dirty: 0, best_effort: 1, frozen: 2}.freeze

      def weaker_verdict(existing, verdict)
        return verdict unless existing

        [existing, verdict].min_by { |v| VERDICT_RANK[v] }
      end

      def group_verdict(ops, classifier)
        return :dirty if ops.any? { |op| op[:body] }
        return :dirty if ops.any? { |op| op[:kind] == :other }

        memos = Rewriters::Memoization.memo_sites(ops)
        if memos.any?
          return group_frozen?(ops, classifier) ? :frozen : :dirty
        end

        writes = ops.select { |op| op[:kind] == :write }
        return :dirty if writes.empty?

        all_safe = writes.all? do |w|
          value = w[:node].value
          best_effort_value?(value) ||
            Rewriters::Memoization.frozen_call?(value) ||
            classifier.classify(value) == :shareable
        end
        wrapped = writes.any? do |w|
          best_effort_value?(w[:node].value)
        end
        (all_safe && wrapped) ? :best_effort : :dirty
      end

      # Matches the emitted setter recipe:
      #   (Ractor.make_shareable(value) rescue value)
      def best_effort_value?(node)
        inner = node
        if inner.is_a?(Prism::ParenthesesNode)
          body = inner.body&.body
          return false unless body && body.size == 1

          inner = body[0]
        end
        return false unless inner.is_a?(Prism::RescueModifierNode)

        call = inner.expression
        call.is_a?(Prism::CallNode) &&
          call.name == :make_shareable &&
          call.receiver.is_a?(Prism::ConstantReadNode) &&
          call.receiver.name == :Ractor
      end

      def group_frozen?(ops, classifier)
        return false if ops.any? { |op| op[:body] }
        return false if ops.any? { |op| op[:kind] == :other }

        memos = Rewriters::Memoization.memo_sites(ops)
        return false if memos.empty?
        return false if
          Rewriters::Memoization.orphan_guards?(ops, memos)

        memo_ops = memos.map { |memo| memo[:op] }
        writes = ops.select { |op| op[:kind] == :write }
        return false unless (writes - memo_ops).empty?

        memos.all? do |memo|
          value = memo[:op][:node].value
          frozen_memo_value?(value, classifier)
        end
      end

      # A bare `.freeze` on a container literal is shallow: the
      # elements stay mutable and the cross-Ractor read still
      # raises, so it must not count as frozen. A `.freeze` on a
      # call result is accepted as the memo recipe (the dynamic
      # probe verifies the value); provably shareable values pass.
      def frozen_memo_value?(value, classifier)
        return true if classifier.classify(value) == :shareable
        return false unless Rewriters::Memoization.frozen_call?(value)

        case value.receiver
        when Prism::ArrayNode, Prism::HashNode,
             Prism::KeywordHashNode
          false
        else
          true
        end
      end

      # "Widget::<Widget>" reads as noise; show "Widget".
      # Nested singleton owners produce nested angle brackets, so
      # the strip repeats until the tail is gone.
      def display_owner(owner)
        name = owner&.name || "?"
        name = name.sub(/::<.*>\z/m, "") while name.match?(/::<.*>\z/m)
        name
      end

      def path_from_uri(uri)
        uri.delete_prefix("file://")
      end

      def source_line(path, line)
        content = @sources[path]
        content ||= File.read(path) if File.file?(path)
        content&.lines&.[](line - 1)&.strip
      end
    end
  end
end
