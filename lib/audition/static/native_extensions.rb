# frozen_string_literal: true

module Audition
  module Static
    # Compiled extensions are invisible to the Ruby scanner, but the
    # one fact that decides their Ractor behavior is visible from
    # outside. Ruby marks every method an extension defines while
    # Init_* runs without rb_ext_ractor_safe(true), and calling any
    # of them from a non-main Ractor raises Ractor::UnsafeError. The
    # declaration is a libruby import, so a compiled file names the
    # symbol or does not, whatever language produced it; sources
    # spell it as rb_ext_ractor_safe(true) or the
    # RB_EXT_RACTOR_SAFE(true) macro (C, Rust via rb-sys, Zig).
    #
    # Compiled files win when present: they are what `require`
    # loads. Sources are consulted only for a checkout that has not
    # been built yet.
    class NativeExtensions
      CHECK = "native-extension"
      SYMBOL = "rb_ext_ractor_safe"
      DECLARATION = /rb_ext_ractor_safe\s*\(\s*true\s*\)/i
      INIT = /\bInit_\w+\s*\(/
      SOURCES = "*.{c,cc,cpp,cxx,m,mm,h,hpp,rs,zig}"
      BUILD_FILES = %w[Cargo.toml build.zig extconf.rb].freeze
      # Harness crates and test trees under ext/ are not compiled
      # into the extension; a fuzz target that links the VM itself
      # may call rb_ext_ractor_safe without the extension doing so.
      HARNESS_DIRS = %w[fuzz benches tests examples test spec].freeze

      SILENT_WHY =
        "Ruby marks every method an extension defines while " \
        "Init_* runs without rb_ext_ractor_safe(true), and calling " \
        "any of them from a non-main Ractor raises " \
        "Ractor::UnsafeError (\"ractor unsafe method called from " \
        "not main ractor\"), whether the extension is C, Rust, or " \
        "Zig (verified on Ruby 4.0.6). "
      # Tails appended to SILENT_WHY at finding time; a constant
      # built with + would hold an unfrozen String.
      COMPILED_TAIL =
        "The declaration is a libruby import, so a compiled file " \
        "that never names the symbol cannot have made it."
      SOURCE_TAIL =
        "These sources never call it, so the compiled extension " \
        "will raise the same way."
      SILENT_FIX =
        "Audit the native code for process-global mutable state " \
        "(statics, caches, VALUEs held outside Ruby objects), then " \
        "call RB_EXT_RACTOR_SAFE(true) first thing in Init_* " \
        "(rb_sys::rb_ext_ractor_safe(true) from Rust). Until then, " \
        "keep every call into this extension on the main Ractor."
      DECLARED_WHY =
        "rb_ext_ractor_safe(true) is the maintainer's assertion " \
        "that the extension keeps no process-global mutable state; " \
        "Ruby does not verify it and neither can audition. Its " \
        "methods run from any Ractor, in parallel, on the strength " \
        "of that assertion alone."
      DECLARED_FIX =
        "Exercise real calls from a non-main Ractor (a script " \
        "probe, or the gem's test suite under Ractor.new) before " \
        "relying on it."

      # @param target [Target]
      # @param compiled_files [Array<String>] compiled extension
      #   files to inspect (defaults to the target's own list; the
      #   CLI passes the config-filtered subset)
      # @return [Array<Finding>]
      def analyze(target, compiled_files: target.compiled_files)
        if compiled_files.any?
          return compiled_files.filter_map { |p| compiled_finding(p) }
        end

        extension_dirs(target.root).map do |dir|
          source_finding(dir, target.root)
        end
      end

      private

      def compiled_finding(path)
        name = File.basename(path)
        if File.binread(path).include?(SYMBOL)
          finding(:info, path, nil,
            "compiled extension #{name} declares Ractor safety " \
            "(imports #{SYMBOL})", DECLARED_WHY, DECLARED_FIX)
        else
          finding(:warning, path, nil,
            "compiled extension #{name} does not declare Ractor " \
            "safety", SILENT_WHY + COMPILED_TAIL, SILENT_FIX)
        end
      rescue SystemCallError
        nil
      end

      # One finding per extension directory (ext/<name>), anchored
      # at the declaration when there is one, else at Init_* or the
      # build file, where the declaration belongs.
      def source_finding(dir, root)
        sources = sources_under(dir)
        label = dir.delete_prefix("#{root}/")
        path, line = locate(sources, DECLARATION)
        if path
          return finding(:info, path, line,
            "extension sources under #{label} declare Ractor " \
            "safety (#{SYMBOL})", DECLARED_WHY, DECLARED_FIX)
        end

        path, line = locate(sources, INIT)
        path ||= build_file(dir)
        finding(:warning, path, line,
          "extension sources under #{label} do not declare Ractor " \
          "safety", SILENT_WHY + SOURCE_TAIL, SILENT_FIX)
      end

      # ext/<name> directories holding native sources; ext/ itself
      # when the sources sit directly in it.
      def extension_dirs(root)
        ext = File.join(root, "ext")
        return [] unless File.directory?(ext)

        dirs = Dir[File.join(ext, "*")].sort.select do |dir|
          File.directory?(dir) && !skipped?(File.basename(dir)) &&
            sources_under(dir).any?
        end
        dirs << ext if Dir[File.join(ext, SOURCES)].any?
        dirs
      end

      def sources_under(dir)
        Dir[File.join(dir, "**", SOURCES)].sort.reject do |path|
          path.delete_prefix("#{dir}/").split("/")[0..-2]
            .any? { |part| skipped?(part) }
        end
      end

      def skipped?(part)
        Target::EXCLUDED_DIRS.include?(part) ||
          Target::BUILD_DIRS.include?(part) ||
          HARNESS_DIRS.include?(part) || part.start_with?(".")
      end

      def locate(sources, pattern)
        sources.each do |path|
          File.foreach(path, mode: "rb").with_index(1) do |text, n|
            return [path, n] if text.match?(pattern)
          end
        end
        nil
      end

      def build_file(dir)
        BUILD_FILES.map { |name| File.join(dir, name) }
          .find { |path| File.file?(path) } || dir
      end

      def finding(severity, path, line, message, why, fix)
        Finding.new(
          check: CHECK, severity: severity, message: message,
          why: why, fix: fix, path: path, line: line
        )
      end
    end
  end
end
