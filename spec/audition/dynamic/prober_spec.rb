# frozen_string_literal: true

require "rbconfig"
require "tmpdir"

RSpec.describe Audition::Dynamic::Prober do
  subject(:prober) { described_class.new(timeout: 30) }

  def write(dir, name, content)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  describe "hostile subprocess behavior" do
    it "is not held hostage by children the target spawns" do
      Dir.mktmpdir do |dir|
        path = write(dir, "spawner.rb", <<~RUBY)
          pid = spawn("sleep", "20")
          Process.detach(pid)
        RUBY

        fast = described_class.new(timeout: 5)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = fast.probe(mode: :script, path: path)
        elapsed =
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(result.passed).to be(true)
        expect(elapsed).to be < 15
      end
    end

    it "reports binary exception messages instead of crashing" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/binboom.rb", <<~RUBY)
          message = (+"boom ").force_encoding("ASCII-8BIT")
          message << 0xFF << 0xFE
          raise RuntimeError, message
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "binboom",
          load_paths: [File.join(dir, "lib")]
        )

        expect(result.passed).to be(false)
        expect(result.findings.first.message)
          .to include("could not load target")
      end
    end

    it "attributes sibling directories with a shared prefix as deps" do
      Dir.mktmpdir do |dir|
        write(dir, "app/lib/own_app.rb", <<~RUBY)
          require "helper_dep"
          module OwnApp
          end
        RUBY
        write(dir, "app-helpers/lib/helper_dep.rb", <<~RUBY)
          module HelperDep
            DIRTY = [1, 2, 3]
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "own_app",
          load_paths: [
            File.join(dir, "app/lib"),
            File.join(dir, "app-helpers/lib")
          ],
          root: File.join(dir, "app")
        )

        dirty = result.findings.find do |f|
          f.message.include?("DIRTY")
        end
        expect(dirty.dependency?).to be(true)
        expect(result.passed).to be(true)
      end
    end
  end

  describe "script probing" do
    it "reports the real IsolationError for a Ractor-hostile script" do
      Dir.mktmpdir do |dir|
        path = write(dir, "hostile.rb", <<~RUBY)
          $counter = 0
          $counter += 1
        RUBY

        result = prober.probe(mode: :script, path: path)

        expect(result.passed).to be(false)
        finding = result.findings.first
        expect(finding.severity).to eq(:error)
        expect(finding.message).to include("Ractor::IsolationError")
        expect(finding.message).to include("global variable")
      end
    end

    it "passes a self-contained script" do
      Dir.mktmpdir do |dir|
        path = write(dir, "clean.rb", "x = [1, 2].sum\nraise unless x == 3\n")

        result = prober.probe(mode: :script, path: path)

        expect(result.passed).to be(true)
        expect(result.findings).to be_empty
      end
    end

    it "distinguishes scripts that fail outside Ractors too" do
      Dir.mktmpdir do |dir|
        path = write(dir, "broken.rb", "raise ArgumentError, 'nope'\n")

        result = prober.probe(mode: :script, path: path)

        expect(result.passed).to be(false)
        expect(result.findings.first.message).to include("outside")
      end
    end
  end

  describe "library probing" do
    it "finds unshareable constants and class-level state at runtime" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/hostile_lib.rb", <<~RUBY)
          module HostileLib
            MUTABLE = [1, 2]
            FROZEN_OK = [3].freeze.map(&:itself).freeze
            SAFE = 42

            @cache = {}
            @@legacy = true

            class Engine
              LOCK = Mutex.new
            end
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "hostile_lib",
          load_paths: [File.join(dir, "lib")]
        )

        expect(result.passed).to be(false)
        messages = result.findings.map(&:message)
        expect(messages.grep(/HostileLib::MUTABLE/)).not_to be_empty
        expect(messages.grep(/HostileLib::Engine::LOCK/)).not_to be_empty
        expect(messages.grep(/@cache/)).not_to be_empty
        expect(messages.grep(/@@legacy/)).not_to be_empty
        expect(messages.grep(/SAFE/)).to be_empty
      end
    end

    it "falls back to the single top-level lib file of the target" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/active_thing.rb", <<~RUBY)
          module ActiveThing
            VERSION = "1.0"
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "activething",
          load_paths: [File.join(dir, "lib")],
          root: dir
        )

        expect(result.raw["error"]).to be_nil
        expect(result.passed).to be(true)
      end
    end

    it "falls back to the slashed feature for dashed gem names" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/acme/widgets.rb", <<~RUBY)
          module Acme
            module Widgets
            end
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "acme-widgets",
          load_paths: [File.join(dir, "lib")]
        )

        expect(result.passed).to be(true)
      end
    end

    it "notes shareable class-level state at info level" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/warmed_lib.rb", <<~RUBY)
          module WarmedLib
            def self.windows?
              return @windows if defined?(@windows)

              @windows = RUBY_PLATFORM.match?(/mswin/).freeze
            end
            windows?
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "warmed_lib",
          load_paths: [File.join(dir, "lib")]
        )

        state = result.findings.select do |f|
          f.check == "runtime-class-state"
        end
        expect(state.size).to eq(1)
        expect(state.first.severity).to eq(:info)
        expect(state.first.why).to include("shareable")
      end
    end
  end

  describe "dependency attribution" do
    it "downgrades findings from dependencies to warnings" do
      Dir.mktmpdir do |own|
        Dir.mktmpdir do |dep|
          write(dep, "lib/dep_lib.rb", <<~RUBY)
            module DepLib
              DIRTY = [1]
            end
          RUBY
          write(own, "lib/own_lib.rb", <<~RUBY)
            require "dep_lib"
            module OwnLib
              ALSO_DIRTY = [2]
            end
          RUBY

          result = prober.probe(
            mode: :require,
            feature: "own_lib",
            load_paths: [File.join(own, "lib"),
              File.join(dep, "lib")],
            root: own
          )

          own_f = result.findings.find do |f|
            f.message.include?("OwnLib::ALSO_DIRTY")
          end
          dep_f = result.findings.find do |f|
            f.message.include?("DepLib::DIRTY")
          end
          expect(own_f.severity).to eq(:error)
          expect(own_f.dependency).to be(false)
          expect(own_f.path).to end_with("own_lib.rb")
          expect(own_f.line).to be_a(Integer)
          expect(dep_f.severity).to eq(:error)
          expect(dep_f.dependency).to be(true)
          expect(result.passed).to be(false)
        end
      end
    end

    # bundler-cache in GitHub Actions vendors every gem into
    # <root>/vendor/bundle; attributing those paths to the target
    # flipped its self-audit from blocked to not_ready.
    it "attributes vendored bundle gems as dependencies" do
      Dir.mktmpdir do |dir|
        gem_lib = "vendor/bundle/ruby/4.0.0/gems/" \
                  "vendored_dep-1.0.0/lib"
        write(dir, "lib/own_app.rb", <<~RUBY)
          require "vendored_dep"
          module OwnApp
          end
        RUBY
        write(dir, "#{gem_lib}/vendored_dep.rb", <<~RUBY)
          module VendoredDep
            DIRTY = [1, 2, 3]
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "own_app",
          load_paths: [File.join(dir, "lib"),
            File.join(dir, gem_lib)],
          root: dir
        )

        dirty = result.findings.find do |f|
          f.message.include?("DIRTY")
        end
        expect(dirty.dependency?).to be(true)
        expect(result.passed).to be(true)
      end
    end

    it "keeps the harness exclusion list in sync with Target" do
      unless defined?(AuditionHarness)
        load File.expand_path(
          "../../../lib/audition/dynamic/harness.rb", __dir__
        )
      end

      expect(AuditionHarness::EXCLUDED_DIRS)
        .to eq(Audition::Target::EXCLUDED_DIRS)
    end
  end

  describe "rack probing" do
    it "boots, serves, and hammers the app across Ractors" do
      Dir.mktmpdir do |dir|
        config_ru = write(dir, "config.ru", <<~RUBY)
          run ->(env) { [200, {}, ["ok"]] }
        RUBY

        result = prober.probe(mode: :rack, config_ru: config_ru)

        expect(result.passed).to be(true)
        expect(result.findings).to be_empty
        concurrency = result.raw.fetch("concurrency")
        expect(concurrency["failures"]).to eq(0)
        served = concurrency["statuses"].values.sum
        expect(served).to eq(
          concurrency["workers"] * concurrency["requests_per_worker"]
        )
      end
    end

    it "reports why a stateful app cannot run inside a Ractor" do
      Dir.mktmpdir do |dir|
        config_ru = write(dir, "config.ru", <<~RUBY)
          $hits = 0
          run ->(env) { $hits += 1; [200, {}, [$hits.to_s]] }
        RUBY

        result = prober.probe(mode: :rack, config_ru: config_ru)

        expect(result.passed).to be(false)
        expect(result.findings.first.severity).to eq(:error)
      end
    end
  end

  describe "capabilities probing" do
    it "reports what this Ruby allows inside Ractors" do
      result = prober.probe(mode: :capabilities)

      caps = result.raw.fetch("capabilities")
      expect(caps.fetch("global variable read")).to include(
        "ok" => false, "error" => "Ractor::IsolationError"
      )
      expect(caps.fetch("ENV read")).to include("ok" => true)
      expect(caps.fetch("require inside Ractor")).to include("ok" => true)
    end
  end
  describe "native extension reporting" do
    # A real silent extension, copied out of Ruby's own arch dir into
    # an excluded (vendor) tree so it counts as a dependency rather
    # than as Ruby itself. Ruby derives Init_ripper from the basename,
    # so the name must survive the copy.
    def vendor_silent_ext(dir)
      ext = RbConfig::CONFIG["DLEXT"]
      src = File.join(RbConfig::CONFIG["archdir"], "ripper.#{ext}")
      dest = File.join(dir, "vendor/ripper_gem/lib/vendored/ripper.#{ext}")
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(src, dest)
      dest
    end

    def native(result)
      result.findings.select { |f| f.check == "runtime-native-extension" }
    end

    it "warns about a dependency's silent compiled extension" do
      Dir.mktmpdir do |dir|
        copy = vendor_silent_ext(dir)
        write(dir, "lib/needs_ripper.rb", <<~RUBY)
          require "vendored/ripper"
          module NeedsRipper
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "needs_ripper",
          load_paths: [File.join(dir, "lib"),
            File.join(dir, "vendor/ripper_gem/lib")],
          root: dir
        )

        finding = native(result).first
        expect(finding).not_to be_nil
        expect(finding.path).to eq(File.realpath(copy))
        expect(finding.severity).to eq(:warning)
        expect(finding.dependency?).to be(true)
        expect(finding.line).to be_nil
        expect(finding.message).to include("does not declare Ractor safety")
        expect(result.raw["native_extensions"]).to include(
          a_hash_including("path" => finding.path, "declares" => false,
            "ruby" => false)
        )
      end
    end

    it "notes a dependency's declared compiled extension" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/needs_rubydex.rb", <<~RUBY)
          require "rubydex"
          module NeedsRubydex
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "needs_rubydex",
          load_paths: [File.join(dir, "lib")],
          root: dir
        )

        finding = native(result).find do |f|
          f.path.match?(/rubydex\.(bundle|so)\z/)
        end
        expect(finding).not_to be_nil
        expect(finding.severity).to eq(:info)
        expect(finding.dependency?).to be(true)
        expect(finding.message).to include("declares Ractor safety")
      end
    end

    it "records Ruby's own extensions without reporting them" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/needs_ripper.rb", <<~RUBY)
          require "ripper"
          module NeedsRipper
          end
        RUBY

        result = prober.probe(
          mode: :require,
          feature: "needs_ripper",
          load_paths: [File.join(dir, "lib")],
          root: dir
        )

        recorded = result.raw["native_extensions"].find do |e|
          e["path"].match?(/ripper\.(bundle|so)\z/)
        end
        expect(recorded).to include("ruby" => true, "declares" => false)
        expect(native(result)).to eq([])
      end
    end

    it "skips compiled files the static check already covers" do
      Dir.mktmpdir do |dir|
        write(dir, "lib/needs_rubydex.rb", <<~RUBY)
          require "rubydex"
          module NeedsRubydex
          end
        RUBY
        spec = Gem::Specification.find_by_name("rubydex")
        known = spec.full_require_paths.flat_map do |rp|
          Dir[File.join(rp, "**", "*.{bundle,so}")]
        end

        result = prober.probe(
          mode: :require,
          feature: "needs_rubydex",
          load_paths: [File.join(dir, "lib")],
          root: dir,
          compiled_files: known
        )

        expect(native(result)).to eq([])
        expect(result.raw["native_extensions"]).to include(
          a_hash_including("known" => true, "own" => true)
        )
      end
    end
  end
end
