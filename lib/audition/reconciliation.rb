# frozen_string_literal: true

module Audition
  # What the dynamic probe proved shareable retires the static
  # pass's guesses about the same objects. A constant the probe
  # read as shareable needs no static warning at all; class-level
  # state whose every value was shareable after boot keeps its
  # finding as an info note, because reads are legal from any
  # Ractor and only a later write would raise.
  module Reconciliation
    PROVEN_WHY =
      "The dynamic probe found every value this variable held " \
      "after boot shareable, so reads from any Ractor are legal; " \
      "only a later write would raise Ractor::IsolationError, " \
      "and writes must stay on the main Ractor."
    PROVEN_FIX =
      "Keep every write at boot on the main Ractor, or warm the " \
      "memo before spawning Ractors."

    # @param findings [Array<Finding>] static findings
    # @param results [Array<Dynamic::Result>] the probes that ran
    # @return [Array<Finding>] findings with the disproven ones
    #   dropped or downgraded
    def self.apply(findings, results)
      constants, ivars = proven(results)
      return findings if constants.empty? && ivars.empty?

      findings.filter_map do |finding|
        case finding.check
        when "mutable-constants"
          site = [realpath(finding.path), finding.line]
          constants.include?(site) ? nil : finding
        when "class-level-state"
          if finding.severity != :info && finding.subject &&
              ivars.include?(finding.subject)
            finding.with(
              severity: :info,
              message: "#{finding.message}, shareable in the " \
                       "dynamic probe",
              why: PROVEN_WHY,
              fix: PROVEN_FIX
            )
          else
            finding
          end
        else
          finding
        end
      end
    end

    # @return [Array(Set, Set)] constant sites ([path, line]) and
    #   class-level ivars ("Owner/@name") observed shareable
    def self.proven(results)
      constants = Set.new
      ivars = Set.new
      results.each do |result|
        raw = result.raw
        next unless raw.is_a?(Hash)

        Array(raw["proven_constants"]).each do |path, line|
          constants << [realpath(path), line]
        end
        Array(raw["class_state"]).each do |entry|
          unshareable = Array(entry["unshareable"])
          owner = entry["const"].to_s
          Array(entry["ivars"]).each do |ivar|
            next if unshareable.include?(ivar)

            ivars << "#{owner}/#{ivar}"
            # A write through a singleton attribute only knows
            # its owner's last segment.
            ivars << "#{owner.split("::").last}/#{ivar}"
          end
        end
      end
      [constants, ivars]
    end

    def self.realpath(path)
      File.realpath(path)
    rescue SystemCallError, TypeError
      path
    end
  end
end
