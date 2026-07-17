# frozen_string_literal: true

module Audition
  # Same-line suppression pragmas:
  #
  #   $flag = true  # audition:disable global-variables
  #   legacy_call   # audition:disable
  #
  # A bare pragma silences every check on that line; otherwise only
  # the listed check names. Applied to any finding carrying a real
  # path and line, including runtime findings.
  class Directives
    PATTERN = /#\s*audition:disable\b[ \t]*(?<list>[^#\n]*)/

    def initialize
      @by_path = {}
    end

    def filter(findings)
      findings.reject { |finding| disabled?(finding) }
    end

    def disabled?(finding)
      return false unless finding.path && finding.line

      checks = directives_for(finding.path)[finding.line]
      return false unless checks

      checks.empty? || checks.include?(finding.check)
    end

    private

    def directives_for(path)
      @by_path[path] ||= scan(path)
    end

    def scan(path)
      return {} unless File.file?(path)

      directives = {}
      File.foreach(path).with_index(1) do |line, number|
        match = PATTERN.match(line)
        next unless match

        directives[number] =
          match[:list].split(/[,\s]+/).reject(&:empty?)
      end
      directives
    rescue SystemCallError
      {}
    end
  end
end
