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

    FAIL_ON_LEVELS = %w[error warning info].freeze

    attr_reader :fail_on, :timeout, :exclude, :disabled_checks

    # @param root [String] directory that may contain .audition.yml
    # @return [Config] empty config when the file is absent
    # @raise [Audition::Error] on malformed YAML, a non-mapping
    #   document, or an unknown fail_on level
    def self.load(root)
      path = File.join(root.to_s, FILE)
      return new(**EMPTY) unless File.file?(path)

      data = YAML.safe_load_file(path) || {}
      validate!(path, data)
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

    def self.validate!(path, data)
      unless data.is_a?(Hash)
        raise Error,
          "#{path}: expected a YAML mapping, got #{data.class}"
      end

      fail_on = data["fail_on"]
      return if fail_on.nil? ||
        FAIL_ON_LEVELS.include?(fail_on.to_s)

      raise Error,
        "#{path}: fail_on must be one of error, warning, or " \
        "info (got #{fail_on.inspect})"
    end
    private_class_method :validate!

    def initialize(fail_on:, timeout:, exclude:, disabled_checks:)
      @fail_on = fail_on
      @timeout = timeout
      @exclude = exclude
      @disabled_checks = disabled_checks
    end

    # Globs follow .gitignore-style expectations: `*` stays within
    # one directory level, `dir/**` covers the whole subtree, and a
    # leading `./` is tolerated.
    def excluded?(relative_path)
      exclude.any? do |raw|
        pattern = raw.delete_prefix("./")
        next true if File.fnmatch?(pattern, relative_path,
          File::FNM_PATHNAME | File::FNM_EXTGLOB)

        prefix = pattern[%r{\A(.+?)/\*\*(?:/\*+)?\z}, 1]
        prefix && relative_path.start_with?("#{prefix}/")
      end
    end

    def check_disabled?(check)
      disabled_checks.include?(check)
    end
  end
end
