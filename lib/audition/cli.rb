# frozen_string_literal: true

require "optparse"
require "table_tennis"

module Audition
  class CLI
    USAGE = "usage: audition [options] TARGET " \
            "(a .rb script, directory, config.ru dir, Rails root, " \
            "gem dir, or installed gem name)"

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      new(stdout: stdout, stderr: stderr).run(argv)
    end

    def initialize(stdout:, stderr:)
      @stdout = stdout
      @stderr = stderr
    end

    def run(argv)
      options = parse(argv.dup)
      return options if options.is_a?(Integer)

      return print_capabilities(options) if options[:capabilities]

      target_arg = options[:args].first
      unless target_arg
        @stderr.puts(USAGE)
        return 2
      end

      target = Target.detect(target_arg)
      target = deps_target(target) if options[:deps]
      if target.type == :bundle
        sweep(target, options)
      else
        audit(target, options)
      end
    rescue Error => e
      @stderr.puts("audition: #{e.message}")
      2
    end

    private

    def parse(argv)
      options = {
        format: :text, fail_on: :error, static_only: false,
        dynamic_only: false, fix: false, unsafe: false,
        dry_run: false, capabilities: false, plain: false,
        timeout: 30, write_baseline: false, no_baseline: false,
        deps: false, explicit: []
      }
      parser = OptionParser.new do |o|
        o.banner = USAGE
        o.on("-f", "--format FORMAT", %w[text json github],
          "output format: text (default), json, or github " \
          "(workflow command annotations)") do |v|
          options[:format] = v.to_sym
        end
        o.on("--compare PATH",
          "report deltas against a previous --format json " \
          "report (text/github formats)") do |v|
          options[:compare] = v
        end
        o.on("--static-only", "skip dynamic in-Ractor probing") do
          options[:static_only] = true
        end
        o.on("--dynamic-only", "skip static analysis") do
          options[:dynamic_only] = true
        end
        o.on("--fix", "apply safe corrections, then re-check") do
          options[:fix] = true
        end
        o.on("--fix-unsafe",
          "also apply semantics-affecting corrections") do
          options[:fix] = true
          options[:unsafe] = true
        end
        o.on("--dry-run",
          "with --fix: show planned edits, change nothing") do
          options[:dry_run] = true
        end
        o.on("--fail-on LEVEL", %w[error warning info],
          "exit 1 threshold (default: error)") do |v|
          options[:fail_on] = v.to_sym
          options[:explicit] << :fail_on
        end
        o.on("--write-baseline",
          "record current findings as the baseline") do
          options[:write_baseline] = true
        end
        o.on("--no-baseline", "ignore an existing baseline") do
          options[:no_baseline] = true
        end
        o.on("--capabilities",
          "probe what this Ruby allows inside Ractors") do
          options[:capabilities] = true
        end
        o.on("--deps",
          "sweep the target's Gemfile.lock gem by gem") do
          options[:deps] = true
        end
        o.on("--timeout SECONDS", Integer,
          "dynamic probe timeout (default: 30)") do |v|
          options[:timeout] = v
          options[:explicit] << :timeout
        end
        o.on("--plain", "disable colors and hyperlinks") do
          options[:plain] = true
        end
        o.on("-v", "--version") do
          @stdout.puts(VERSION)
          return 0
        end
        o.on("-h", "--help") do
          @stdout.puts(o)
          return 0
        end
      end
      options[:args] = parser.parse(argv)
      options
    rescue OptionParser::ParseError => e
      @stderr.puts("audition: #{e.message}")
      @stderr.puts(USAGE)
      2
    end

    def audit(target, options)
      config = Config.load(target.root)
      options = apply_config(options, config)
      directives = Directives.new
      findings = []
      unless options[:dynamic_only]
        findings = filter(static_findings(target, config),
          directives, config)
        findings = run_fix(target, findings, options) if options[:fix]
      end

      results = []
      if target.entry && !options[:static_only]
        results << prober(options).probe(target.entry)
      end

      all = findings +
        filter(results.flat_map(&:findings), directives, config)

      if options[:write_baseline]
        recorded = Baseline.write(target.root, all)
        @stdout.puts(
          "baseline written: #{recorded} finding(s) recorded in " \
          "#{Baseline.path_for(target.root)}"
        )
        return 0
      end

      all, baselined = apply_baseline(all, target, options)

      report = Report.new(
        target_type: target.type,
        target_root: target.root,
        findings: all,
        dynamic_results: results,
        unsafe_fixes: options[:unsafe] ? 0 : Fixer.unsafe_gain(all),
        baselined: baselined
      )
      emit(report, options)
      if options[:compare] && options[:format] != :json
        emit_comparison(report, options)
      end
      exit_code(report, options)
    end

    def emit_comparison(report, options)
      old = begin
        JSON.parse(File.read(options[:compare]))
      rescue JSON::ParserError, SystemCallError => e
        raise Error, "cannot read #{options[:compare]}: #{e.message}"
      end

      budget = Hash.new(0)
      old.fetch("findings", []).each do |f|
        budget[[f["check"], f["path"], f["message"]]] += 1
      end
      total_old = budget.values.sum

      introduced = report.findings.reject do |f|
        key = [f.check, f.path, f.message]
        next false unless budget[key].positive?

        budget[key] -= 1
        true
      end
      fixed = total_old -
        (report.findings.size - introduced.size)

      s = style(options)
      @stdout.puts(
        "  compared to #{options[:compare]}: " \
        "#{s.green("#{fixed} fixed")} · " \
        "#{s.red("#{introduced.size} introduced")}"
      )
      introduced.each do |f|
        @stdout.puts("    + #{f.message} (#{f.location})")
      end
    end

    def apply_config(options, config)
      merged = options.dup
      if config.fail_on && !options[:explicit].include?(:fail_on)
        merged[:fail_on] = config.fail_on
      end
      if config.timeout && !options[:explicit].include?(:timeout)
        merged[:timeout] = config.timeout
      end
      merged
    end

    def filter(findings, directives, config)
      directives.filter(findings).reject do |finding|
        config.check_disabled?(finding.check)
      end
    end

    def apply_baseline(findings, target, options)
      return [findings, 0] if options[:no_baseline]

      baseline = Baseline.load(target.root)
      return [findings, 0] unless baseline

      baseline.filter(findings, root: target.root)
    end

    def static_findings(target, config)
      files = target.ruby_files.reject do |file|
        config.excluded?(file.delete_prefix("#{target.root}/"))
      end
      per_file = Static::Analyzer.new.analyze_paths(files)
      per_file + Static::GraphAudit.new.analyze_paths(files)
    end

    def run_fix(target, findings, options)
      fixer = Fixer.new(unsafe: options[:unsafe])
      if options[:dry_run]
        render_preview(fixer.preview(findings), options)
        return findings
      end

      applied = fixer.apply(findings)
      total = applied.values.sum
      @stdout.puts(
        "fixed #{total} finding(s) in #{applied.size} file(s)"
      )
      return findings unless total.positive?

      filter(static_findings(target, Config.load(target.root)),
        Directives.new, Config.load(target.root))
    end

    def render_preview(previews, options)
      s = style(options)
      previews.each do |preview|
        @stdout.puts(s.bold(preview[:path]))
        preview[:hunks].each do |hunk|
          @stdout.puts("  @ line #{hunk[:line]}")
          hunk[:old].each_line do |line|
            @stdout.puts(s.red("  - #{line.chomp}"))
          end
          hunk[:new].each_line do |line|
            @stdout.puts(s.green("  + #{line.chomp}"))
          end
        end
      end
      @stdout.puts("dry run: no files were changed")
    end

    def prober(options)
      Dynamic::Prober.new(timeout: options[:timeout])
    end

    def emit(report, options)
      case options[:format]
      when :json then @stdout.puts(report.to_json)
      when :github then @stdout.puts(report.to_github)
      else @stdout.puts(report.to_text(style: style(options)))
      end
    end

    def style(options)
      if options[:plain]
        Report::Style.new(color: false, hyperlinks: false)
      else
        Report::Style.detect(io: @stdout)
      end
    end

    def exit_code(report, options)
      threshold = SEVERITIES.fetch(options[:fail_on])
      failed =
        report.findings.any? do |f|
          f.severity_rank >= threshold
        end || report.dynamic_results.any? { |r| !r.passed }
      failed ? 1 : 0
    end

    def deps_target(target)
      return target if target.type == :bundle

      lockfile = File.join(target.root, "Gemfile.lock")
      unless File.file?(lockfile)
        raise Error, "no Gemfile.lock found in #{target.root}"
      end

      Target.detect(lockfile)
    end

    VERDICT_CELLS = {
      :not_ready => "not ready", :blocked => "blocked",
      :risky => "risky", :ready => "ready", nil => "-"
    }.freeze

    def sweep(target, options)
      sweeper = BundleSweep.new(
        lockfile: target.entry[:lockfile],
        static_only: options[:static_only],
        timeout: options[:timeout]
      )
      rows = sweeper.rows(progress: sweep_progress)

      if options[:format] == :json
        emit_sweep_json(rows)
      else
        emit_sweep_table(rows)
      end
      (rows.any? { |r| r.verdict == :not_ready }) ? 1 : 0
    end

    def sweep_progress
      return nil unless @stderr.respond_to?(:tty?) && @stderr.tty?

      lambda do |row, done, total|
        @stderr.puts("audited #{row.name} (#{done}/#{total})")
      end
    end

    def emit_sweep_table(rows)
      ready = rows.count { |r| r.verdict == :ready }
      table = rows.map do |r|
        {
          "gem" => r.name,
          "version" => r.version,
          "verdict" => VERDICT_CELLS.fetch(r.verdict),
          "errors" => r.errors,
          "dep errors" => r.dep_errors,
          "warnings" => r.warnings,
          "fixable" => r.fixable,
          "status" => r.status
        }
      end
      @stdout.puts(TableTennis.new(table, layout: false).to_s)
      @stdout.puts(
        "#{ready} of #{rows.size} gems ractor-ready"
      )
    end

    def emit_sweep_json(rows)
      @stdout.puts(JSON.pretty_generate(
        "audition" => VERSION,
        "ruby" => RUBY_VERSION,
        "bundle" => rows.map do |r|
          {
            "gem" => r.name,
            "version" => r.version,
            "verdict" => r.verdict&.to_s,
            "errors" => r.errors,
            "dependency_errors" => r.dep_errors,
            "warnings" => r.warnings,
            "fixable" => r.fixable,
            "status" => r.status
          }
        end
      ))
    end

    def print_capabilities(options)
      result = prober(options).probe(mode: :capabilities)
      caps = result.raw["capabilities"]
      unless caps
        @stderr.puts(
          "audition: capabilities probe failed: #{result.raw}"
        )
        return 2
      end

      rows = caps.map do |probe, info|
        {
          "works in Ractor" => probe,
          "ok" => info["ok"] ? "yes" : "no",
          "raises" => info["error"] || "-"
        }
      end
      @stdout.puts("ruby #{RUBY_VERSION} at #{RbConfig.ruby}")
      @stdout.puts(TableTennis.new(rows, layout: false).to_s)
      0
    end
  end
end
