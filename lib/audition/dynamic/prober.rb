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
      HARNESS = File.expand_path("harness.rb", __dir__)

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
      # @param entry [Hash] `:mode` plus mode-specific keys
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
        ractor = run("script_ractor", "path" => path)
        if ractor["ok"]
          return Result.new(mode: :script, raw: ractor,
            findings: [], passed: true)
        end

        main = run("script_main", "path" => path)
        finding = script_finding(path, ractor, main)
        Result.new(mode: :script,
          raw: {"ractor" => ractor, "main" => main},
          findings: [finding], passed: false)
      end

      def script_finding(path, ractor, main)
        if main["ok"]
          error = describe(ractor)
          Finding.new(
            check: "dynamic-script",
            severity: :error,
            message: "raises inside a Ractor: #{error}",
            why: "The script ran fine on the main Ractor but " \
                 "failed under Ractor.new; the static findings " \
                 "usually pinpoint the exact line.",
            fix: "Fix the static findings for this file, then " \
                 "re-audition.",
            path: path,
            line: nil
          )
        else
          Finding.new(
            check: "dynamic-script",
            severity: :error,
            message: "fails outside Ractors too: #{describe(main)}",
            why: "The script does not even run on the main " \
                 "Ractor, so Ractor-readiness cannot be assessed.",
            fix: "Make the script run standalone first.",
            path: path,
            line: nil
          )
        end
      end

      def probe_require(entry)
        feature = entry[:feature]
        raw = run("require",
          "feature" => feature,
          "load_paths" => Array(entry[:load_paths]),
          "root" => entry[:root])
        findings = runtime_findings(raw, feature)
        Result.new(mode: :require, raw: raw, findings: findings,
          passed: own_clean?(findings))
      end

      def probe_rails(entry)
        raw = run("rails",
          "environment" => entry[:environment],
          "root" => entry[:root])
        boot = raw["boot"]
        if boot && !boot["ok"]
          finding = Finding.new(
            check: "dynamic-rails",
            severity: :error,
            message: "Rails failed to boot: #{describe(boot)}",
            why: "Ractor-readiness cannot be assessed until the " \
                 "application boots.",
            fix: "Boot the app (bin/rails runner 1) and fix " \
                 "whatever breaks, then re-audition.",
            path: entry[:environment],
            line: nil
          )
          return Result.new(mode: :rails, raw: raw,
            findings: [finding], passed: false)
        end

        findings = runtime_findings(raw, entry[:environment])
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
        raw = run("rack", "config_ru" => config_ru)
        findings = rack_findings(raw, config_ru)
        passed = raw.dig("ractor_boot_call", "ok") == true &&
          raw.dig("concurrency", "failures").to_i.zero?
        Result.new(mode: :rack, raw: raw, findings: findings,
          passed: passed)
      end

      def probe_capabilities
        raw = run("capabilities")
        Result.new(mode: :capabilities, raw: raw, findings: [],
          passed: raw.key?("capabilities"))
      end

      # -- findings builders ---------------------------------------

      def runtime_findings(raw, label)
        if raw["error"]
          return [load_failure_finding(raw, label)]
        end

        findings = []
        raw.fetch("unshareable_constants", []).each do |entry|
          findings << runtime_finding(
            entry, label,
            check: "runtime-unshareable-constant",
            severity: :error,
            message: "constant #{entry["const"]} holds an " \
                     "unshareable #{entry["class"]}",
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
        findings
      end

      def class_state_finding(entry, label)
        unshareable = entry.fetch("unshareable", [])
        hot = unshareable.any?
        detail =
          hot ? " (unshareable: #{unshareable.join(", ")})" : ""
        runtime_finding(
          entry, label,
          check: "runtime-class-state",
          severity: hot ? :error : :warning,
          message: "class-level state " \
                   "#{entry["ivars"].join(", ")} on " \
                   "#{entry["const"]}#{detail}",
          why: "Writes raise Ractor::IsolationError from non-main " \
               "Ractors; reads raise too while the value is " \
               "unshareable. #{RUNTIME_WHY}",
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

      def load_failure_finding(raw, label)
        Finding.new(
          check: "runtime-load",
          severity: :error,
          message: "could not load target: #{describe(raw)}",
          why: "Ractor-readiness cannot be assessed until the " \
               "target loads.",
          fix: "Make `require` succeed on a bare Ruby first.",
          path: label,
          line: nil
        )
      end

      def rack_findings(raw, config_ru)
        if raw.dig("ractor_boot_call", "ok")
          return concurrency_findings(raw, config_ru)
        end

        if raw["rack_available"] == false
          return [Finding.new(
            check: "dynamic-rack",
            severity: :warning,
            message: "rack gem not available in the probe process",
            why: "The rack probe boots the app via Rack::Builder.",
            fix: "Install rack next to audition and re-run.",
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
        [Finding.new(
          check: "dynamic-rack",
          severity: :error,
          message: "boot + call inside a Ractor failed: #{detail}",
          why: "#{why} #{RUNTIME_WHY}",
          fix: "Remove global/class-level state touched during " \
               "boot and request handling; keep middleware config " \
               "frozen; open connections per-Ractor.",
          path: config_ru,
          line: nil
        )]
      end

      def concurrency_findings(raw, config_ru)
        stats = raw["concurrency"] || {}
        failures = stats["failures"].to_i
        return [] if failures.zero?

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
          path: config_ru,
          line: nil
        )]
      end

      def describe(hash)
        error = hash.is_a?(Hash) ? (hash["error"] || hash) : {}
        klass = error["class"] || "UnknownError"
        message = error["message"] || hash.inspect[0, 120]
        "#{klass}: #{message}"
      end

      # -- subprocess plumbing -------------------------------------

      def run(mode, payload = {})
        out, err, timed_out = execute(mode, payload)
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
          "message" => (err || "").split("\n").last(5).join("; ")
        }}
      end

      def execute(mode, payload)
        cmd = [@ruby, "-W0", HARNESS, mode]
        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait|
          stdin.write(JSON.generate(payload))
          stdin.close
          out_reader = Thread.new { stdout.read }
          err_reader = Thread.new { stderr.read }
          if wait.join(@timeout)
            [out_reader.value, err_reader.value, false]
          else
            begin
              Process.kill("KILL", wait.pid)
            rescue Errno::ESRCH
              nil
            end
            [out_reader.value.to_s, err_reader.value.to_s, true]
          end
        end
      end
    end
  end
end
