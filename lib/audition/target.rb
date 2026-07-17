# frozen_string_literal: true

module Audition
  # Figures out what the user pointed us at and what that means for
  # scanning (which .rb files) and dynamic probing (which entry).
  #
  # Detection precedence for directories: Rails beats Rack (a Rails
  # root always has a config.ru), Rack beats gem (an app may vendor a
  # gemspec), gem beats plain directory.
  class Target
    EXCLUDED_DIRS = %w[
      vendor node_modules tmp log coverage pkg .git .bundle
    ].freeze

    attr_reader :type, :root, :ruby_files, :entry

    def self.detect(raw)
      raw = normalize(raw)
      if File.file?(raw)
        from_file(raw)
      elsif File.directory?(raw)
        from_directory(raw)
      else
        from_gem_name(raw)
      end
    end

    def self.from_file(path)
      if File.basename(path) == "Gemfile.lock"
        return new(
          type: :bundle,
          root: File.expand_path("..", path),
          ruby_files: [],
          entry: {mode: :bundle, lockfile: path}
        )
      end
      unless path.end_with?(".rb", ".ru")
        raise Error, "#{path} is not a Ruby file"
      end

      new(
        type: :script,
        root: File.dirname(path),
        ruby_files: [path],
        entry: {mode: :script, path: path}
      )
    end

    def self.from_directory(dir)
      application_rb = File.join(dir, "config", "application.rb")
      config_ru = File.join(dir, "config.ru")
      gemspec = Dir[File.join(dir, "*.gemspec")].first

      if File.file?(application_rb)
        rails_target(dir)
      elsif File.file?(config_ru)
        rack_target(dir, config_ru)
      elsif gemspec
        gem_dir_target(dir, gemspec)
      else
        new(
          type: :directory,
          root: dir,
          ruby_files: glob(dir),
          entry: nil
        )
      end
    end

    def self.from_gem_name(name)
      spec = Gem::Specification.find_by_name(name)
      new(
        type: :gem,
        root: spec.full_gem_path,
        ruby_files: spec.require_paths.flat_map do |rp|
          glob(File.join(spec.full_gem_path, rp))
        end,
        entry: {mode: :require, feature: name,
                root: spec.full_gem_path}
      )
    rescue Gem::MissingSpecError
      raise Error,
        "#{name} is not a file, directory, or installed gem"
    end

    def self.rails_target(dir)
      files = %w[app lib config].flat_map { |d| glob(File.join(dir, d)) }
      files << File.join(dir, "config.ru")
      new(
        type: :rails,
        root: dir,
        ruby_files: files.select { |f| File.file?(f) },
        entry: {
          mode: :rails,
          environment: File.join(dir, "config", "environment.rb"),
          root: dir
        }
      )
    end

    def self.rack_target(dir, config_ru)
      new(
        type: :rack,
        root: dir,
        ruby_files: [config_ru] + glob(dir),
        entry: {mode: :rack, config_ru: config_ru}
      )
    end

    def self.gem_dir_target(dir, gemspec)
      lib = File.join(dir, "lib")
      new(
        type: :gem,
        root: dir,
        ruby_files: glob(lib),
        entry: {
          mode: :require,
          feature: File.basename(gemspec, ".gemspec"),
          load_paths: [lib],
          root: dir
        }
      )
    end

    # Trailing slashes would break the prefix-stripping in glob
    # ("dir//" never matches), silently excluding every file of a
    # relative target.
    def self.normalize(raw)
      return raw if raw == "/"

      raw.sub(%r{/+\z}, "")
    end

    def self.glob(dir)
      dir = normalize(dir)
      Dir[File.join(dir, "**", "*.rb")].reject do |path|
        relative = path.delete_prefix("#{dir}/")
        parts = relative.split("/")
        parts.any? { |p| EXCLUDED_DIRS.include?(p) || p.start_with?(".") }
      end.sort
    end

    private_class_method :from_file, :from_directory, :from_gem_name,
      :rails_target, :rack_target, :gem_dir_target,
      :glob, :normalize

    def initialize(type:, root:, ruby_files:, entry:)
      @type = type
      @root = root
      @ruby_files = ruby_files
      @entry = entry
    end
  end
end
