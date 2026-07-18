# frozen_string_literal: true

require "rubydex"

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

      # @param sources [Hash{String => String}] path => source
      # @return [Array<Finding>]
      def analyze_sources(sources)
        graph = Rubydex::Graph.new
        sources.each do |path, code|
          graph.index_source(path, code, "ruby")
        end
        @sources = sources
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
        each_local_definition(decl).map do |defn|
          finding_at(
            defn,
            check: "class-level-state",
            message: "class-level instance variable #{variable} " \
                     "on #{owner}",
            why: STATE_WHY,
            fix: STATE_FIX
          )
        end
      end

      def each_local_definition(decl)
        decl.definitions.reject do |defn|
          defn.location.uri.start_with?("rubydex:")
        end
      end

      def finding_at(defn, check:, message:, why:, fix:)
        path = path_from_uri(defn.location.uri)
        line = defn.location.start_line + 1
        Finding.new(
          check: check,
          severity: :error,
          message: message,
          why: why,
          fix: fix,
          path: path,
          line: line,
          source: source_line(path, line)
        )
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
