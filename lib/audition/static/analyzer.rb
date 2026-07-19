# frozen_string_literal: true

require "etc"

module Audition
  module Static
    # Runs the per-file Prism checks over sources or paths.
    class Analyzer
      # @param checks [Array<Class>] check classes to run
      #   (defaults to {Checks.all})
      def initialize(checks: Checks.all)
        @checks = checks
      end

      # @param source [String] Ruby source text
      # @param path [String] path used in findings
      # @return [Array<Finding>]
      def analyze_source(source, path:)
        analyze_file(SourceFile.new(source: source, path: path))
      end

      # @param path [String] file to read and analyze
      # @return [Array<Finding>]
      def analyze_path(path)
        analyze_file(SourceFile.read(path))
      end

      PARALLEL_THRESHOLD = 16

      # Scans files across Ractors when there are enough of them to
      # be worth the spawn cost. Checks are plain shareable classes
      # with deeply frozen catalogs, findings copy back through
      # `Ractor#value`, and anything unexpected falls back to the
      # serial path.
      #
      # @param paths [Array<String>] files to analyze
      # @param workers [Integer] Ractor count (defaults to
      #   processor count minus one)
      # @param threshold [Integer] minimum file count before
      #   Ractors are used at all
      # @return [Array<Finding>]
      def analyze_paths(paths, workers: default_workers,
        threshold: PARALLEL_THRESHOLD)
        if paths.size < threshold || workers <= 1
          return paths.flat_map { |path| analyze_path(path) }
        end

        parallel_analyze(paths, workers)
      rescue Ractor::Error => e
        # The silent fallback would otherwise mask a check that is
        # itself Ractor-hostile; surface it under -w.
        if $VERBOSE
          warn "audition: parallel scan fell back to serial: " \
               "#{e.class}: #{e.message}"
        end
        paths.flat_map { |path| analyze_path(path) }
      end

      private

      def parallel_analyze(paths, workers)
        experimental = Warning[:experimental]
        Warning[:experimental] = false
        slice = (paths.size / workers.to_f).ceil
        checks = @checks
        paths.each_slice(slice).map do |chunk|
          Ractor.new(chunk, checks) do |files, active_checks|
            analyzer = Analyzer.new(checks: active_checks)
            files.flat_map { |file| analyzer.analyze_path(file) }
          end
        end.flat_map(&:value)
      ensure
        Warning[:experimental] = experimental
      end

      def default_workers
        [Etc.nprocessors - 1, 1].max
      end

      def analyze_file(file)
        return [syntax_finding(file)] unless file.valid_syntax?

        @checks.flat_map { |check| check.call(file) }.sort_by(&:line)
      end

      private

      def syntax_finding(file)
        error = file.syntax_errors.first
        Finding.new(
          check: "syntax",
          severity: :error,
          message: "file does not parse: #{error&.message}",
          why: "Audition can only analyze valid Ruby.",
          fix: "Fix the syntax error first.",
          path: file.path,
          line: error&.location&.start_line
        )
      end
    end
  end
end
