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

    # Directories holding the target's tests rather than the code
    # a production boot loads. The default; `test_dirs` in
    # .audition.yml replaces it for a project that files them
    # elsewhere.
    TEST_DIRS = %w[test spec features].freeze

    # Cargo and Zig build output: full of .so/.dylib artifacts that
    # are not the extension `require` loads.
    BUILD_DIRS = %w[target zig-out].freeze

    # What Ruby loads as a native extension (RbConfig DLEXT is
    # "bundle" on macOS, "so" everywhere else, Windows included).
    COMPILED = "*.{bundle,so}"

    # Generated type stubs. The extension is the convention; where
    # the generator writes them is not, so they are found by
    # extension anywhere in the tree.
    STUBS = "*.rbi"

    # @return [Symbol] one of `:script`, `:gem`, `:rack`, `:rails`,
    #   `:directory`, `:bundle`
    attr_reader :type

    # @return [String] the target's root directory
    attr_reader :root

    # @return [Array<String>] Ruby files to scan statically
    attr_reader :ruby_files

    # @return [Array<String>] compiled extension files (.bundle/.so)
    #   shipped with the target; empty for scripts and file lists
    attr_reader :compiled_files

    # @return [Array<String>] generated type stubs (.rbi) found
    #   anywhere in the target's tree
    attr_reader :stub_files

    # @return [Hash, nil] dynamic probe entry (`:mode` plus
    #   mode-specific keys), nil for static-only targets
    attr_reader :entry

    # Detects what `raw` points at and builds the target.
    #
    # @param raw [String] a `.rb`/`.ru` file, a directory, a
    #   `Gemfile.lock`, or an installed gem name
    # @return [Target]
    # @raise [Audition::Error] when nothing matches
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

    # Builds a static-only target from an explicit file list, the
    # shape git hooks hand over (lefthook's {staged_files},
    # pre-commit's filename arguments). Config, pragmas, and the
    # baseline resolve against the working directory, which is the
    # repository root when a hook manager runs the command.
    #
    # @param paths [Array<String>] `.rb`/`.ru` files
    # @return [Target] type `:files`, no dynamic entry
    # @raise [Audition::Error] when a path is not a Ruby file
    def self.for_files(paths)
      paths.each do |path|
        unless File.file?(path) && path.end_with?(".rb", ".ru")
          raise Error, "#{path} is not a Ruby file"
        end
      end

      new(
        type: :files,
        root: Dir.pwd,
        ruby_files: paths,
        entry: nil,
        stub_files: stubs(Dir.pwd)
      )
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
        # A file inside a Rails root cannot run standalone; the
        # script probe would report a misleading boot failure, so
        # such files stay static-only.
        entry: rails_member?(path) ? nil : {mode: :script, path: path},
        stub_files: stubs(File.dirname(path))
      )
    end

    def self.rails_member?(path)
      dir = File.dirname(File.expand_path(path))
      until dir == (parent = File.dirname(dir))
        return true if File.file?(
          File.join(dir, "config", "application.rb")
        )

        dir = parent
      end
      false
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
          entry: nil,
          compiled_files: compiled(dir),
          stub_files: stubs(dir)
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
                load_paths: spec.full_require_paths,
                root: spec.full_gem_path},
        compiled_files: compiled_for(spec),
        stub_files: stubs(spec.full_gem_path)
      )
    rescue Gem::MissingSpecError
      raise Error,
        "#{name} is not a file, directory, or installed gem"
    end

    # An app's own Ruby is not confined to app/lib/config: local
    # gems, engines and tests boot into the same process, so the
    # whole root is scanned.
    def self.rails_target(dir)
      files = glob(dir)
      files << File.join(dir, "config.ru")
      new(
        type: :rails,
        root: dir,
        ruby_files: files.select { |f| File.file?(f) },
        entry: {
          mode: :rails,
          environment: File.join(dir, "config", "environment.rb"),
          root: dir
        },
        compiled_files: compiled(dir),
        stub_files: stubs(dir)
      )
    end

    def self.rack_target(dir, config_ru)
      new(
        type: :rack,
        root: dir,
        ruby_files: [config_ru] + glob(dir),
        entry: {mode: :rack, config_ru: config_ru, root: dir},
        compiled_files: compiled(dir),
        stub_files: stubs(dir)
      )
    end

    # Reading require_paths off the gemspec would mean evaluating
    # it, which the static pass never does; `lib` is the packaging
    # default, and a gem that keeps its code elsewhere falls back to
    # the whole checkout rather than scanning nothing.
    def self.gem_dir_target(dir, gemspec)
      lib = File.join(dir, "lib")
      paths = File.directory?(lib) ? [lib] : [dir]
      new(
        type: :gem,
        root: dir,
        ruby_files: paths.flat_map { |path| glob(path) },
        entry: {
          mode: :require,
          feature: File.basename(gemspec, ".gemspec"),
          load_paths: paths,
          root: dir
        },
        compiled_files: compiled(dir),
        stub_files: stubs(dir)
      )
    end

    # Trailing slashes would break the prefix-stripping in glob
    # ("dir//" never matches), silently excluding every file of a
    # relative target.
    def self.normalize(raw)
      return raw if raw == "/"

      raw.sub(%r{/+\z}, "")
    end

    def self.glob(dir, pattern = "*.rb", skip: EXCLUDED_DIRS)
      dir = normalize(dir)
      Dir[File.join(dir, "**", pattern)].reject do |path|
        relative = path.delete_prefix("#{dir}/")
        parts = relative.split("/")
        parts.any? { |p| skip.include?(p) || p.start_with?(".") }
      end.sort
    end

    # Generated type stubs anywhere under a directory.
    #
    # @param dir [String]
    # @return [Array<String>]
    def self.stubs(dir)
      glob(dir, STUBS)
    end

    # macOS debug-symbol bundles (x.bundle.dSYM/...) carry a file
    # with the extension's name that nothing ever loads.
    def self.compiled(dir)
      glob(dir, COMPILED, skip: EXCLUDED_DIRS + BUILD_DIRS).reject do |p|
        p.split("/").any? { |part| part.end_with?(".dSYM") }
      end
    end

    # Compiled extension files of an installed gem. RubyGems builds
    # a source gem into its extension dir and also copies the result
    # under lib/, so the same file shows up on two require paths;
    # keep one per require-relative name.
    #
    # @param spec [Gem::Specification]
    # @return [Array<String>]
    def self.compiled_for(spec)
      spec.full_require_paths.flat_map do |rp|
        compiled(rp).map { |path| [path.delete_prefix("#{rp}/"), path] }
      end.uniq(&:first).map(&:last)
    end

    private_class_method :from_file, :from_directory, :from_gem_name,
      :rails_target, :rack_target, :gem_dir_target,
      :rails_member?, :glob, :compiled, :normalize

    def initialize(type:, root:, ruby_files:, entry:,
      compiled_files: [], stub_files: [])
      @type = type
      @root = root
      @ruby_files = ruby_files
      @entry = entry
      @compiled_files = compiled_files
      @stub_files = stub_files
    end

    # Whether a path is test/spec code rather than code the
    # production boot loads.
    #
    # @param path [String] absolute or root-relative
    # @param dirs [Array<String>] directory names that hold tests
    # @return [Boolean]
    def test_file?(path, dirs: TEST_DIRS)
      relative = File.expand_path(path, root)
        .delete_prefix("#{root}/")
      parts = relative.split("/")
      parts[0..-2].any? { |p| dirs.include?(p) } ||
        parts.last.to_s.end_with?("_test.rb", "_spec.rb")
    end
  end
end
