# frozen_string_literal: true

require "yaml"

module Audition
  # Project configuration from .audition.yml at the target root:
  #
  #   fail_on: warning
  #   timeout: 60
  #   exclude:
  #     - legacy/**
  #     - db/schema.rb
  #   checks:
  #     disable:
  #       - at-exit
  #
  # CLI flags always win over config values.
  class Config
    FILE = ".audition.yml"

    EMPTY = Ractor.make_shareable(
      {fail_on: nil, timeout: nil, exclude: [],
       disabled_checks: []}
    )

    attr_reader :fail_on, :timeout, :exclude, :disabled_checks

    # @param root [String] directory that may contain .audition.yml
    # @return [Config] empty config when the file is absent
    # @raise [Audition::Error] on malformed YAML
    def self.load(root)
      path = File.join(root.to_s, FILE)
      return new(**EMPTY) unless File.file?(path)

      data = YAML.safe_load_file(path) || {}
      new(
        fail_on: data["fail_on"]&.to_sym,
        timeout: data["timeout"],
        exclude: Array(data["exclude"]).map(&:to_s),
        disabled_checks:
          Array(data.dig("checks", "disable")).map(&:to_s)
      )
    rescue Psych::Exception => e
      raise Error, "#{path}: #{e.message}"
    end

    def initialize(fail_on:, timeout:, exclude:, disabled_checks:)
      @fail_on = fail_on
      @timeout = timeout
      @exclude = exclude
      @disabled_checks = disabled_checks
    end

    def excluded?(relative_path)
      exclude.any? do |pattern|
        next true if File.fnmatch?(pattern, relative_path)

        prefix = pattern[%r{\A(.+?)/\*\*(?:/\*+)?\z}, 1]
        prefix && relative_path.start_with?("#{prefix}/")
      end
    end

    def check_disabled?(check)
      disabled_checks.include?(check)
    end
  end
end
