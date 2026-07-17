# frozen_string_literal: true

require "bundler"

module Audition
  # Audits every gem in a Gemfile.lock and ranks the results:
  # the "can my whole app move to Ractors" view. Static analysis
  # runs in worker threads; dynamic probes are subprocesses, so
  # they genuinely parallelize.
  class BundleSweep
    CONCURRENCY = 4

    Row = Data.define(:name, :version, :verdict, :errors,
      :dep_errors, :warnings, :fixable, :status)

    VERDICT_ORDER = {
      :not_ready => 0, :blocked => 1, :risky => 2, :ready => 3, nil => 4
    }.freeze

    # @param lockfile [String] path to a Gemfile.lock
    # @param static_only [Boolean] skip dynamic probes
    # @param timeout [Integer] per-probe timeout in seconds
    # @param concurrency [Integer] worker thread count
    def initialize(lockfile:, static_only: false, timeout: 30,
      concurrency: CONCURRENCY)
      @lockfile = lockfile
      @static_only = static_only
      @timeout = timeout
      @concurrency = concurrency
    end

    # Audits every locked gem and ranks the results, worst first.
    #
    # @param progress [Proc, nil] called with (row, done, total)
    #   as each gem finishes
    # @return [Array<Row>]
    def rows(progress: nil)
      gems = locked_gems
      queue = Thread::Queue.new
      gems.each { |g| queue << g }
      queue.close

      collected = []
      mutex = Thread::Mutex.new
      @concurrency.times.map do
        Thread.new do
          while (name, version = queue.pop)
            row = audit_gem(name, version)
            mutex.synchronize do
              collected << row
              progress&.call(row, collected.size, gems.size)
            end
          end
        end
      end.each(&:join)

      collected.sort_by do |row|
        [VERDICT_ORDER.fetch(row.verdict), -row.errors, row.name]
      end
    end

    private

    def locked_gems
      parser = Bundler::LockfileParser.new(File.read(@lockfile))
      parser.specs.map { |s| [s.name, s.version.to_s] }.uniq
    end

    def audit_gem(name, version)
      target = Target.detect(name)
      findings = static_findings(target)
      results = dynamic_results(target)
      report = Report.new(
        target_type: :gem,
        target_root: target.root,
        findings: findings + results.flat_map(&:findings),
        dynamic_results: results
      )
      counts = report.counts
      Row.new(
        name: name, version: version, verdict: report.verdict,
        errors: counts[:error], dep_errors: counts[:dep_error],
        warnings: counts[:warning], fixable: counts[:fixable],
        status: "ok"
      )
    rescue Error
      Row.new(
        name: name, version: version, verdict: nil, errors: 0,
        dep_errors: 0, warnings: 0, fixable: 0,
        status: "not installed"
      )
    end

    # Worker threads already parallelize across gems; per-gem
    # scanning stays serial to avoid a Ractor storm.
    def static_findings(target)
      per_file = Static::Analyzer.new
        .analyze_paths(target.ruby_files, workers: 1)
      per_file + Static::GraphAudit.new
        .analyze_paths(target.ruby_files)
    end

    def dynamic_results(target)
      return [] if @static_only || target.entry.nil?

      prober = Dynamic::Prober.new(timeout: @timeout)
      [prober.probe(target.entry)]
    end
  end
end
