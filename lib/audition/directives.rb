# frozen_string_literal: true

require "prism"

module Audition
  # Same-line suppression pragmas:
  #
  #   $flag = true  # audition:disable global-variables
  #   legacy_call   # audition:disable
  #
  # A bare pragma silences every check on that line; otherwise only
  # the listed check names. Applied to any finding carrying a real
  # path and line, including runtime findings. Pragmas are read
  # from Prism's comment list, never from raw lines: pragma-shaped
  # text inside a string literal is data, not a directive.
  class Directives
    PATTERN = /#\s*audition:disable\b[ \t]*(?<list>[\w \t,-]*)/

    def initialize
      @by_path = {}
    end

    # @param findings [Array<Finding>]
    # @return [Array<Finding>] findings not silenced by a pragma
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

    # Every pragma comment on a line contributes; an explicit
    # disable is never shadowed by an earlier pragma, and a bare
    # pragma (empty list) wins over any list.
    def scan(path)
      return {} unless File.file?(path)

      directives = {}
      Prism.parse_file(path).comments.each do |comment|
        comment.slice.scan(PATTERN) do
          line = comment.location.start_line
          checks = Regexp.last_match[:list]
            .split(/[,\s]+/).reject(&:empty?)
          if directives.key?(line)
            existing = directives[line]
            directives[line] =
              if existing.empty? || checks.empty?
                []
              else
                existing | checks
              end
          else
            directives[line] = checks
          end
        end
      end
      directives
    rescue SystemCallError
      {}
    end
  end
end
