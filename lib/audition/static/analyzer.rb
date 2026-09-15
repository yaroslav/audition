# frozen_string_literal: true

require_relative "work_split"

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

      # Workers report in batches: a port message per file would
      # cost more than the redraw it feeds.
      TICK_STRIDE = 25

      # Scans files across Ractors when there are enough of them to
      # be worth the spawn cost. Checks are plain shareable classes
      # with deeply frozen catalogs, findings copy back through
      # `Ractor#value`, and anything unexpected falls back to the
      # serial path.
      #
      # @param paths [Array<String>] files to analyze
      # @param workers [Integer, nil] Ractor count (defaults to
      #   {#default_workers})
      # @param threshold [Integer] minimum file count before
      #   Ractors are used at all
      # @param progress [Progress] ticked per file
      # @return [Array<Finding>]
      def analyze_paths(paths, workers: nil,
        threshold: PARALLEL_THRESHOLD, progress: Progress::SILENT)
        workers ||= default_workers
        if paths.size < threshold || workers <= 1
          return serial_analyze(paths, progress)
        end

        parallel_analyze(paths, workers, progress)
      rescue Ractor::Error => e
        # The silent fallback would otherwise mask a check that is
        # itself Ractor-hostile; surface it under -w.
        if $VERBOSE
          warn "Audition: parallel scan fell back to serial: " \
               "#{e.class}: #{e.message}"
        end
        progress.ractors = nil
        serial_analyze(paths, progress)
      end

      private

      def serial_analyze(paths, progress)
        paths.flat_map do |path|
          findings = analyze_path(path)
          progress.tick
          findings
        end
      end

      # A port carries counts out of the workers while they run:
      # the alternative is a status line frozen for the whole
      # parallel phase, which is most of a large scan.
      def parallel_analyze(paths, workers, progress)
        experimental = Warning[:experimental]
        Warning[:experimental] = false
        checks = @checks
        port = progress.enabled? ? Ractor::Port.new : nil
        chunks = balanced_chunks(paths, workers)
        progress.ractors = chunks.size
        ractors = chunks.map do |chunk|
          # The sentinel goes out through `ensure` so a worker that
          # raises still releases the drain loop; the exception
          # itself still surfaces from `Ractor#value`.
          Ractor.new(chunk, checks, port) do |files, active, tap|
            analyzer = Analyzer.new(checks: active)
            pending = 0
            begin
              files.flat_map do |file|
                findings = analyzer.analyze_path(file)
                pending += 1
                if tap && pending >= TICK_STRIDE
                  tap.send(pending)
                  pending = 0
                end
                findings
              end
            ensure
              tap&.send(pending)
              tap&.send(:done)
            end
          end
        end
        drain(port, ractors.size, progress) if port
        ractors.flat_map(&:value)
      ensure
        Warning[:experimental] = experimental
      end

      def drain(port, workers, progress)
        done = 0
        while done < workers
          message = port.receive
          if message == :done
            done += 1
          else
            progress.tick(message)
          end
        end
      rescue
        # Narration is cosmetic; a closed port ends it quietly and
        # `Ractor#value` still reports what went wrong.
        nil
      end

      def default_workers
        WorkSplit.workers
      end

      # Byte size stands in for parse cost, and the stat it costs
      # is nothing beside the parse it schedules.
      def balanced_chunks(paths, workers)
        WorkSplit.chunks(
          paths.map { |path| [path, file_size(path)] }, workers
        )
      end

      def file_size(path)
        File.size(path)
      rescue SystemCallError
        0
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
