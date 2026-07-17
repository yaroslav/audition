# frozen_string_literal: true

require "json"

module Audition
  # Incremental-adoption ledger (.audition-baseline.json): known
  # findings recorded as counts per "check|relative/path" so line
  # drift never invalidates it. Present findings up to the recorded
  # count are hidden; anything beyond is new and fails as usual.
  class Baseline
    FILE = ".audition-baseline.json"

    def self.path_for(root)
      File.join(root.to_s, FILE)
    end

    def self.write(root, findings)
      counts = Hash.new(0)
      findings.each { |f| counts[key(f, root)] += 1 }
      File.write(
        path_for(root),
        JSON.pretty_generate(counts.sort.to_h) << "\n"
      )
      counts.values.sum
    end

    def self.load(root)
      path = path_for(root)
      return nil unless File.file?(path)

      new(JSON.parse(File.read(path)))
    rescue JSON::ParserError => e
      raise Error, "#{path}: #{e.message}"
    end

    def self.key(finding, root)
      relative =
        finding.path.to_s.delete_prefix("#{root}/")
      "#{finding.check}|#{relative}"
    end

    def initialize(counts)
      @counts = counts
    end

    # Returns [visible_findings, hidden_count]; budget per key is
    # consumed in finding order.
    def filter(findings, root:)
      budget = @counts.dup
      hidden = 0
      visible = findings.reject do |finding|
        key = self.class.key(finding, root)
        next false unless budget.fetch(key, 0).positive?

        budget[key] -= 1
        hidden += 1
        true
      end
      [visible, hidden]
    end
  end
end
