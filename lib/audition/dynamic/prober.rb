# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

module Audition
  module Dynamic
    # Outcome of one dynamic probe.
    #
    # @!attribute [r] mode
    #   @return [Symbol] `:script`, `:require`, `:rack`, `:rails`,
    #     or `:capabilities`
    # @!attribute [r] raw
    #   @return [Hash] the harness's parsed JSON, verbatim
    # @!attribute [r] findings
    #   @return [Array<Finding>] findings derived from `raw`
    # @!attribute [r] passed
    #   @return [Boolean] whether the target's own surface passed
    Result = Data.define(:mode, :raw, :findings, :passed)

    # Spawns the harness subprocess per probe mode, parses its JSON,
    # and converts observations into findings.
    class Prober
      HARNESS = File.expand_path("harness.rb", __dir__).freeze

      RUNTIME_WHY =
        "Observed on the live object graph after loading the " \
        "target; this is ground truth, not a static guess."

      # @param ruby [String] Ruby executable for the harness
      # @param timeout [Integer] seconds before a probe subprocess
      #   is killed
      def initialize(ruby: RbConfig.ruby, timeout: 30)
        @ruby = ruby
        @timeout = timeout
      end

      # Runs the probe described by a {Target#entry} hash.
      #
      # @param entry [Hash] `:mode` plus mode-specific keys; require
      #   and rails entries may carry `:compiled_files`, the target's
      #   own compiled extensions, which the static check already
      #   covers and the probe therefore does not report again
      # @return [Result]
      # @raise [Audition::Error] on an unknown mode
      def probe(entry)
        case (entry[:mode] || entry["mode"]).to_sym
        when :script then probe_script(entry)
        when :require then probe_require(entry)
        when :rack then probe_rack(entry)
        when :rails then probe_rails(entry)
        when :capabilities then probe_capabilities
        else
          raise Error, "unknown dynamic probe mode in #{entry}"
        end
      end

      private

      def probe_script(entry)
        path = entry[:path]
        ractor = run("script_ractor", {"path" => path})
        if ractor["ok"]
          return Result.new(mode: :script, raw: ractor,
            findings: [], passed: true)
        end

        main = run("script_main", {"path" => path})
        finding = script_finding(path, ractor, main)
        Result.new(mode: :script,
          raw: {"ractor" => ractor, "main" => main},
          findings: [finding], passed: false)
      end

      def script_finding(path, ractor, main)
        if main["ok"]
          error = describe(ractor)
          site = failure_site(ractor, prefix: "#{path}:")
          Finding.new(
            check: "dynamic-script",
            severity: :error,
            message: "raises inside a Ractor: #{error}",
            why: "The script ran fine on the main Ractor but " \
                 "failed under Ractor.new; the static findings " \
                 "usually pinpoint the exact line.",
            fix: "Fix the static findings for this file, then " \
                 "re-run Audition.",
            path: path,
            line: site&.last
          )
        else
          site = failure_site(main, prefix: "#{path}:")
          Finding.new(
            check: "dynamic-script",
            severity: :error,
            message: "fails outside Ractors too: #{describe(main)}",
            why: "The script does not even run on the main " \
                 "Ractor, so Ractor-readiness cannot be assessed.",
            fix: "Make the script run standalone first.",
            path: path,
            line: site&.last
          )
        end
      end

      def probe_require(entry)
        feature = entry[:feature]
        raw = run("require",
          {"feature" => feature,
           "load_paths" => Array(entry[:load_paths]),
           "root" => entry[:root],
           "known_compiled" => Array(entry[:compiled_files]),
           "max_constants" => entry[:max_constants]})
        findings = runtime_findings(raw, feature,
          root: entry[:root])
        Result.new(mode: :require, raw: raw, findings: findings,
          passed: own_clean?(findings))
      end

      def probe_rails(entry)
        raw = run("rails",
          {"environment" => entry[:environment],
           "root" => entry[:root],
           "known_compiled" => Array(entry[:compiled_files]),
           "max_constants" => entry[:max_constants]},
          root: entry[:root])
        boot = raw["boot"]
        findings = runtime_findings(raw, entry[:environment],
          root: entry[:root])
        if boot && !boot["ok"]
          # The sweep of whatever loaded before the failure stays:
          # a partial dynamic result beats none.
          why = "Ractor-readiness cannot be fully assessed " \
                "until the application boots."
          if raw["scanned"].to_i.positive?
            why += " Findings below cover what loaded before " \
                   "the failure."
          end
          site = failure_site(boot, prefix: own_prefix(entry[:root]))
          findings.unshift(Finding.new(
            check: "dynamic-rails",
            severity: :error,
            message: "Rails failed to boot: #{describe(boot)}",
            why: why,
            fix: "Boot the app (bin/rails runner 1) and fix " \
                 "whatever breaks, then re-run Audition.",
            path: site&.first || entry[:environment],
            line: site&.last
          ))
          return Result.new(mode: :rails, raw: raw,
            findings: findings, passed: false)
        end

        Result.new(mode: :rails, raw: raw, findings: findings,
          passed: own_clean?(findings))
      end

      # A probe passes when the target's own surface is clean;
      # dependency errors surface in the findings and drive the
      # blocked verdict instead.
      def own_clean?(findings)
        findings.none? { |f| f.error? && !f.dependency? }
      end

      def probe_rack(entry)
        config_ru = entry[:config_ru]
        root = entry[:root] || File.dirname(config_ru)
        raw = run("rack",
          {"config_ru" => config_ru,
           "root" => root,
           "known_compiled" => Array(entry[:compiled_files]),
           "max_constants" => entry[:max_constants]},
          root: root)
        findings = rack_findings(raw, config_ru, root)
        findings += runtime_findings(raw, config_ru, root: root) unless raw["error"]
        passed = raw.dig("ractor_boot_call", "ok") == true &&
          raw.dig("concurrency", "failures").to_i.zero? &&
          own_clean?(findings)
        Result.new(mode: :rack, raw: raw, findings: findings,
          passed: passed)
      end

      def probe_capabilities
        raw = run("capabilities")
        Result.new(mode: :capabilities, raw: raw, findings: [],
          passed: raw.key?("capabilities"))
      end

      # -- findings builders ---------------------------------------

      def runtime_findings(raw, label, root: nil)
        if raw["error"]
          return [load_failure_finding(raw, label, root)]
        end

        findings = []
        raw.fetch("unshareable_constants", []).each do |entry|
          blocker = entry["blocker"]
          detail =
            if blocker.nil? || blocker == entry["class"]
              ""
            elsif entry["blocker_nested"]
              " (blocked by #{blocker} inside)"
            else
              " (just not frozen)"
            end
          findings << runtime_finding(
            entry, label,
            check: "runtime-unshareable-constant",
            severity: :error,
            message: "constant #{entry["const"]} holds an " \
                     "unshareable #{entry["class"]}#{detail}",
            why: "Reading it from a non-main Ractor raises " \
                 "Ractor::IsolationError. #{RUNTIME_WHY}",
            fix: "Freeze it deeply at definition time " \
                 "(Ractor.make_shareable) or make it per-Ractor."
          )
        end
        raw.fetch("class_state", []).each do |entry|
          findings << class_state_finding(entry, label)
        end
        raw.fetch("class_variables", []).each do |entry|
          findings << runtime_finding(
            entry, label,
            check: "runtime-class-variable",
            severity: :error,
            message: "class variable(s) " \
                     "#{entry["cvars"].join(", ")} on " \
                     "#{entry["const"]}",
            why: "Class variables raise Ractor::IsolationError " \
                 "on any access from a non-main Ractor. " \
                 "#{RUNTIME_WHY}",
            fix: "Replace with frozen constants, instance state, " \
                 "or Ractor-local storage."
          )
        end
        raw.fetch("native_extensions", []).each do |entry|
          next if entry["ruby"] || entry["known"]

          findings << native_finding(entry, label)
        end
        # A truncated sweep must never read as a clean one.
        if raw["truncated"]
          findings.unshift(Finding.new(
            check: "runtime-scan",
            severity: :warning,
            message: "constant sweep truncated after " \
                     "#{raw["scanned"]} constants " \
                     "(limit #{raw["limit"]})",
            why: "Constants beyond the limit were never probed, " \
                 "so their absence from the findings proves " \
                 "nothing.",
            fix: "Raise the probe's max_constants and re-run.",
            path: label,
            line: nil
          ))
        end
        findings
      end

      # Ruby's own extensions are left to Ruby, and files the static
      # check already reported are not repeated; what remains is the
      # native code the target pulls in through its dependencies.
      def native_finding(entry, label)
        name = File.basename(entry["path"])
        native = Static::NativeExtensions
        if entry["declares"]
          runtime_finding(
            entry, label,
            check: "runtime-native-extension",
            severity: :info,
            message: "compiled extension #{name} declares Ractor " \
                     "safety (imports #{native::SYMBOL})",
            why: "#{native::DECLARED_WHY} Loaded while requiring " \
                 "the target.",
            fix: native::DECLARED_FIX
          )
        else
          runtime_finding(
            entry, label,
            check: "runtime-native-extension",
            severity: :warning,
            message: "compiled extension #{name} does not declare " \
                     "Ractor safety",
            why: "#{native::SILENT_WHY}#{native::COMPILED_TAIL} " \
                 "Loaded while requiring the target.",
            fix: native::SILENT_FIX
          )
        end
      end

      # Class-level state holding only shareable values is the
      # warmed frozen-memoization shape: reads are legal from any
      # Ractor, so it rates an info note; unshareable values are
      # hard errors.
      def class_state_finding(entry, label)
        unshareable = entry.fetch("unshareable", [])
        hot = unshareable.any?
        detail =
          hot ? " (unshareable: #{unshareable.join(", ")})" : ""
        why =
          if hot
            "Writes raise Ractor::IsolationError from non-main " \
            "Ractors; reads raise too while the value is " \
            "unshareable. #{RUNTIME_WHY}"
          else
            "Every value observed here is shareable, so reads " \
            "from non-main Ractors are legal; only late writes " \
            "would raise Ractor::IsolationError. #{RUNTIME_WHY}"
          end
        runtime_finding(
          entry, label,
          check: "runtime-class-state",
          severity: hot ? :error : :info,
          message: "class-level state " \
                   "#{entry["ivars"].join(", ")} on " \
                   "#{entry["const"]}#{detail}",
          why: why,
          fix: "Precompute and freeze at load, use " \
               "Ractor.store_if_absent, or keep per-Ractor state."
        )
      end

      # Findings keep their true severity; those tracing to a
      # dependency's source file carry dependency: true so the
      # report can attribute them (and the verdict can distinguish
      # not_ready from blocked). Unknown origins count as own.
      def runtime_finding(entry, label, check:, severity:,
        message:, why:, fix:)
        Finding.new(
          check: check,
          severity: severity,
          message: message,
          why: why,
          fix: fix,
          path: entry["path"] || label,
          line: entry["line"],
          dependency: !entry.fetch("own", true)
        )
      end

      def load_failure_finding(raw, label, root = nil)
        site = failure_site(raw, prefix: own_prefix(root))
        Finding.new(
          check: "runtime-load",
          severity: :error,
          message: "could not load target: #{describe(raw)}",
          why: "Ractor-readiness cannot be assessed until the " \
               "target loads.",
          fix: "Make `require` succeed on a bare Ruby first.",
          path: site&.first || label,
          line: site&.last
        )
      end

      def rack_findings(raw, config_ru, root = nil)
        if raw.dig("ractor_boot_call", "ok")
          return concurrency_findings(raw, config_ru, root)
        end

        if raw["rack_available"] == false
          return [Finding.new(
            check: "dynamic-rack",
            severity: :warning,
            message: "rack gem not available in the probe process",
            why: "The rack probe boots the app via Rack::Builder.",
            fix: "Install rack next to Audition and re-run.",
            path: config_ru,
            line: nil
          )]
        end

        detail = describe(raw["ractor_boot_call"] || raw)
        why =
          if raw["main_boot_error"]
            "config.ru does not even boot on the main Ractor " \
            "(#{describe(raw["main_boot_error"])})."
          else
            "Ractor web servers boot the app once per Ractor; " \
            "booting config.ru and serving one GET / inside a " \
            "Ractor failed."
          end
        site = failure_site(raw["ractor_boot_call"],
          prefix: own_prefix(root)) ||
          failure_site({"error" => raw["main_boot_error"]},
            prefix: own_prefix(root))
        [Finding.new(
          check: "dynamic-rack",
          severity: :error,
          message: "boot + call inside a Ractor failed: #{detail}",
          why: "#{why} #{RUNTIME_WHY}",
          fix: "Remove global/class-level state touched during " \
               "boot and request handling; keep middleware config " \
               "frozen; open connections per-Ractor.",
          path: site&.first || config_ru,
          line: site&.last
        )]
      end

      def concurrency_findings(raw, config_ru, root = nil)
        stats = raw["concurrency"] || {}
        failures = stats["failures"].to_i
        return [] if failures.zero?

        site = failure_site({"error" => stats["first_error"]},
          prefix: own_prefix(root))
        [Finding.new(
          check: "dynamic-rack-concurrency",
          severity: :error,
          message: "#{failures} of #{stats["workers"]} concurrent " \
                   "Ractors failed: " \
                   "#{describe(stats["first_error"])}",
          why: "Single-Ractor serving worked; failures appeared " \
               "only under concurrent load, which usually means " \
               "shared state races. #{RUNTIME_WHY}",
          fix: "Look for process-global state touched during " \
               "request handling and boot.",
          path: site&.first || config_ru,
          line: site&.last
        )]
      end

      # A backtrace frame inside the target names the failing
      # line; frames outside it stay unattributed rather than
      # pinning a finding to a dependency's file.
      BACKTRACE_FRAME = /\A(.+?):(\d+):in /

      def failure_site(hash, prefix:)
        prefixes = Array(prefix)
        return nil if prefixes.empty? || !hash.is_a?(Hash)

        error = hash["error"].is_a?(Hash) ? hash["error"] : hash
        frame = Array(error["backtrace"]).find do |f|
          f.is_a?(String) && prefixes.any? { |p| f.start_with?(p) }
        end
        match = frame&.match(BACKTRACE_FRAME)
        match && [match[1], Integer(match[2], 10)]
      end

      # require realpaths frames while eval keeps paths as given,
      # so a symlinked root (macOS /var) must match both spellings.
      def own_prefix(root)
        return nil if root.nil?

        [root + File::SEPARATOR,
          realpath(root) + File::SEPARATOR].uniq
      end

      def realpath(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def describe(hash)
        error = hash.is_a?(Hash) ? (hash["error"] || hash) : {}
        klass = error["class"] || "UnknownError"
        message = error["message"] || hash.inspect[0, 120]
        "#{klass}: #{message}"
      end

      # -- subprocess plumbing -------------------------------------

      # Harness output can carry arbitrary target bytes; force
      # valid UTF-8 before any string work or a binary exception
      # message crashes the whole run.
      def run(mode, payload = {}, root: nil)
        out, err, timed_out = execute(mode, payload, root: root)
        out = sanitize(out)
        err = sanitize(err)
        if timed_out
          return {"error" => {
            "class" => "AuditionTimeout",
            "message" => "harness exceeded #{@timeout}s"
          }}
        end
        JSON.parse(out)
      rescue JSON::ParserError
        {"error" => {
          "class" => "HarnessFailure",
          "message" => err.split("\n").last(5).join("; ")
        }}
      end

      def sanitize(text)
        (text || "").dup.force_encoding(Encoding::UTF_8).scrub
      end

      # The harness leads its own process group so a timeout kills
      # every descendant, and the pipe readers are bounded: a
      # child the target spawned inherits our pipes and would
      # otherwise hold the read until it exits, defeating the
      # timeout and leaving orphans behind.
      def execute(mode, payload, root: nil)
        cmd = [@ruby, "-W0", HARNESS, mode]
        # An app boots against its own bundle: the subprocess runs
        # from the target root with the target's Gemfile. When
        # Audition itself runs under bundle exec, the inherited
        # Bundler environment (RUBYOPT's -rbundler/setup above all)
        # would activate Audition's bundle inside the child before
        # the harness starts, so it is scrubbed first.
        env = {}
        opts = {pgroup: true}
        if root && File.directory?(root)
          opts[:chdir] = root
          gemfile = File.join(root, "Gemfile")
          if File.file?(gemfile)
            ENV.each_key do |key|
              env[key] = nil if key.start_with?("BUNDLE") ||
                %w[RUBYOPT RUBYLIB].include?(key)
            end
            env["BUNDLE_GEMFILE"] = gemfile
          end
        end
        Open3.popen3(env, *cmd, **opts) do |stdin, stdout, stderr, wait|
          stdin.write(JSON.generate(payload))
          stdin.close
          out_reader = reader(stdout)
          err_reader = reader(stderr)
          timed_out = wait.join(@timeout).nil?
          kill_group(wait.pid) if timed_out
          unless drain(out_reader, err_reader)
            kill_group(wait.pid)
            unless drain(out_reader, err_reader)
              close_quietly(stdout)
              close_quietly(stderr)
            end
          end
          [out_reader.value.to_s, err_reader.value.to_s, timed_out]
        end
      end

      # Accumulates chunks so a forced close still yields what
      # arrived before it; a plain IO#read would lose everything.
      def reader(io)
        Thread.new do
          buffer = String.new(encoding: Encoding::BINARY)
          begin
            loop { buffer << io.readpartial(65_536) }
          rescue IOError
            buffer
          end
          buffer
        end
      end

      def drain(*threads)
        threads.all? { |thread| thread.join(2) }
      end

      def kill_group(pid)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def close_quietly(io)
        io.close
      rescue IOError
        nil
      end
    end
  end
end
