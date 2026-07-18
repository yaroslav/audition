# frozen_string_literal: true

require "rubydex"
require_relative "../rewriters"

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
        "Precompute and freeze the value at load time (for " \
        "per-subclass values, in the inherited hook). For " \
        "collections, rebuild and refreeze on write, " \
        "Rails-style copy-on-write: self.list = " \
        "(list + [item]).freeze; never mutate in place. As a " \
        "last resort use Ractor.store_if_absent for lazy " \
        "initialization or per-Ractor state in " \
        "Ractor.current[:key]."
      FROZEN_MEMO_WHY =
        "Every write memoizes a shareable (frozen) value, so " \
        "non-main Ractors can read it once it has been " \
        "computed; only the first write must happen on the " \
        "main Ractor, or it raises Ractor::IsolationError. " \
        "This is the pattern Rails core uses for its own " \
        "memoized class state."
      FROZEN_MEMO_FIX =
        "Warm the cache at boot, before spawning Ractors: call " \
        "the memoizing method from an initializer or on_load " \
        "hook. If the value genuinely must be computed at " \
        "runtime, proxy the write to the main Ractor or use " \
        "Ractor.store_if_absent."

      # @param sources [Hash{String => String}] path => source
      # @return [Array<Finding>]
      def analyze_sources(sources)
        graph = Rubydex::Graph.new
        sources.each do |path, code|
          graph.index_source(path, code, "ruby")
        end
        @sources = sources
        @frozen_memos = frozen_memo_map(sources)
        audit(graph)
      end

      # rubydex's index_all descends directories but skips bare file
      # lists, so files are fed through index_source individually.
      #
      # @param paths [Array<String>] files to index and audit
      # @return [Array<Finding>]
      def analyze_paths(paths)
        sources = {}
        paths.each do |path|
          sources[path] = File.read(path)
        rescue SystemCallError
          next
        end
        analyze_sources(sources)
      end

      private

      def audit(graph)
        graph.resolve
        findings = []
        graph.declarations.each do |decl|
          case decl
          when Rubydex::ClassVariable
            findings.concat(class_variable_findings(decl))
          when Rubydex::InstanceVariable
            findings.concat(class_state_findings(decl))
          end
        end
        findings.sort_by { |f| [f.path, f.line] }
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
        frozen = @frozen_memos["#{owner}/#{variable}"] == :frozen
        each_local_definition(decl).map do |defn|
          if frozen
            finding_at(
              defn,
              check: "class-level-state",
              severity: :info,
              message: "frozen memoization #{variable} on " \
                       "#{owner}; warm it on the main Ractor",
              why: FROZEN_MEMO_WHY,
              fix: FROZEN_MEMO_FIX
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

      # Frozen memoization, the shape Rails core ships: every
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
            verdict =
              group_frozen?(ops, classifier) ? :frozen : :dirty
            map[key] =
              (map[key] == :dirty) ? :dirty : verdict
          end
        end
        map
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
          Rewriters::Memoization.frozen_call?(value) ||
            classifier.classify(value) == :shareable
        end
      end

      # "Payments::<Payments>" reads as noise; show "Payments".
      def display_owner(owner)
        (owner&.name || "?").sub(/::<[^>]+>\z/, "")
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
