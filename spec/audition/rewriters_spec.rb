# frozen_string_literal: true

require "tmpdir"
require "open3"

RSpec.describe "unsafe rewriters" do
  def write(dir, name, content)
    path = File.join(dir, name)
    File.write(path, content)
    path
  end

  def all_findings(path)
    Audition::Static::Analyzer.new.analyze_path(path) +
      Audition::Static::GraphAudit.new.analyze_paths([path])
  end

  def fix!(path, unsafe: true)
    Audition::Fixer.new(unsafe: unsafe).apply(all_findings(path))
  end

  it "clears an all-literal file with shareable_constant_value" do
    Dir.mktmpdir do |dir|
      path = write(dir, "consts.rb", <<~RUBY)
        # frozen_string_literal: true

        CACHE = {}
        TABLES = [[1], [2]]
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content.lines[1])
        .to eq("# shareable_constant_value: literal\n")
      expect(content).to include("CACHE = {}\n")
      expect(content).not_to include("make_shareable")
      expect(all_findings(path)).to be_empty

      out, err, = Open3.capture3(RbConfig.ruby, path)
      expect(err).to eq(""), err
      expect(out).to eq("")
    end
  end

  it "keeps shareable_constant_value away from frozen literals" do
    Dir.mktmpdir do |dir|
      path = write(dir, "curves.rb", <<~RUBY)
        # frozen_string_literal: true

        CURVES = {
          "prime256v1" => { algorithm: "ES256" }
        }.freeze
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).not_to include("shareable_constant_value")
      expect(content).to include(
        "CURVES = Ractor.make_shareable({"
      )
      _, err, = Open3.capture3(RbConfig.ruby, path)
      expect(err).to eq(""), err
    end
  end

  it "applies edits by byte offset in multibyte files" do
    Dir.mktmpdir do |dir|
      path = write(dir, "unicode.rb", <<~RUBY)
        # arrows: ↓ ■ ○ and more ünïcode before the constant
        DYNAMIC = compute
        TABLE = { 65516 => "↓", 65517 => "■" }
        TAIL = 42
      RUBY

      fix!(path)

      content = File.read(path)
      expect(Prism.parse(content).success?).to be(true)
      expect(content).to include("TAIL = 42")
      expect(content).to include(
        'Ractor.make_shareable({ 65516 => "↓", 65517 => "■" })'
      )
    end
  end

  it "ignores doc comments that look like magic comments" do
    Dir.mktmpdir do |dir|
      path = write(dir, "docs.rb", <<~RUBY)
        # Usage:
        #
        #   I18n.t: 'date.formats.short'
        #
        NAME = "audition"
      RUBY

      fix!(path)

      lines = File.read(path).lines
      expect(lines.first)
        .to eq("# shareable_constant_value: literal\n")
    end
  end

  it "refuses magic comments when the file mutates its constants" do
    Dir.mktmpdir do |dir|
      path = write(dir, "params.rb", <<~RUBY)
        PARAMS_CONFIG = {}

        def self.record(value)
          PARAMS_CONFIG[:key] = value
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).not_to include("shareable_constant_value")
      expect(content).to include("PARAMS_CONFIG = {}\n")

      script = <<~RUBY
        require #{path.inspect}
        record(1)
        raise "lost" unless PARAMS_CONFIG[:key] == 1
        print "mutable-constant-intact"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("mutable-constant-intact"), err
    end
  end

  it "refuses shareable_constant_value for containers of locals" do
    Dir.mktmpdir do |dir|
      path = write(dir, "racc.rb", <<~RUBY)
        table = build_table
        RACC_ARG = [table, 42]
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).not_to include("shareable_constant_value")
      expect(content).to include(
        "RACC_ARG = Ractor.make_shareable([table, 42])"
      )
    end
  end

  it "inserts frozen_string_literal when strings are the issue" do
    Dir.mktmpdir do |dir|
      path = write(dir, "strings.rb", <<~RUBY)
        NAME = "audition"
        DYNAMIC = compute_thing
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content.lines.first)
        .to eq("# frozen_string_literal: true\n")
      expect(content).to include(%(NAME = "audition"\n))
      expect(all_findings(path)).to be_empty
    end
  end

  it "keeps inline wraps when a constant defies classification" do
    Dir.mktmpdir do |dir|
      path = write(dir, "mixed.rb", <<~RUBY)
        CACHE = {}
        DYNAMIC = compute_thing
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).not_to include("shareable_constant_value")
      expect(content).to include("CACHE = Ractor.make_shareable({})")
    end
  end

  it "keeps nil invalidation working for reset caches" do
    Dir.mktmpdir do |dir|
      path = write(dir, "store.rb", <<~RUBY)
        module Store
          def self.pattern
            @pattern ||= compute
          end

          def self.compute = "v\#{@count = (@count || 0) + 1}"

          def self.reset!
            @pattern = nil
          end
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include(
        'Ractor.current[:"Store/@pattern"] ||= compute'
      )
      expect(content).to include(
        'Ractor.current[:"Store/@pattern"] = nil'
      )
      expect(content).not_to include("store_if_absent")

      script = <<~RUBY
        require #{path.inspect}
        first = Store.pattern
        cached = Store.pattern
        Store.reset!
        second = Store.pattern
        raise "no cache" unless first == "v1" && cached == "v1"
        raise "reset lost" unless second == "v2"
        print "invalidation-works"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("invalidation-works"), err
    end
  end

  it "freezes memoized values and keeps the memoization" do
    Dir.mktmpdir do |dir|
      path = write(dir, "platform.rb", <<~RUBY)
        module Platform
          class << self
            def windows?
              return @windows if defined?(@windows)

              @windows = RUBY_PLATFORM.match?(/mswin|mingw/)
            end

            def separator
              return @separator if defined?(@separator)

              @separator = windows? ? ";" : ":"
            end
          end
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include(
        "@windows = Ractor.make_shareable(" \
        "RUBY_PLATFORM.match?(/mswin|mingw/))"
      )
      expect(content).to include(
        '@separator = (windows? ? ";" : ":").freeze'
      )
      expect(content).to include("defined?(@windows)")
      expect(all_findings(path).none?(&:error?)).to be(true)

      script = <<~RUBY
        Warning[:experimental] = false
        require #{path.inspect}
        cold = begin
          Ractor.new { Platform.separator }.value
        rescue Ractor::RemoteError
          :raised
        end
        raise "memoization was lost" unless cold == :raised
        Platform.separator
        warm = Ractor.new { Platform.separator }.value
        raise "broken" unless warm == ":"
        print "works-once-warmed"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("works-once-warmed"), err
    end
  end

  it "freezes the final write of multi-statement memo bodies" do
    Dir.mktmpdir do |dir|
      path = write(dir, "runner.rb", <<~RUBY)
        class Runner
          def self.binary_path
            return @binary_path if defined?(@binary_path)

            executable = "bun"
            @binary_path = File.join("/opt", executable)
          end
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include(%(executable = "bun"\n))
      expect(content).to include(
        "@binary_path = Ractor.make_shareable(" \
        'File.join("/opt", executable))'
      )
      expect(content).to include("defined?(@binary_path)")
      expect(all_findings(path).none?(&:error?)).to be(true)
    end
  end

  it "leaves sibling reads of the memoized ivar alone" do
    Dir.mktmpdir do |dir|
      path = write(dir, "paths.rb", <<~RUBY)
        class Paths
          def self.root
            return @root if defined?(@root)

            @root = File.expand_path("..")
          end

          def self.doc = File.join(@root, "doc")
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include(
        '@root = Ractor.make_shareable(File.expand_path(".."))'
      )
      expect(content).to include('File.join(@root, "doc")')
      expect(all_findings(path).none?(&:error?)).to be(true)
    end
  end

  it "wraps config setters in best-effort make_shareable" do
    Dir.mktmpdir do |dir|
      path = write(dir, "config.rb", <<~RUBY)
        module Config
          def self.backend = @backend

          def self.backend=(value)
            @backend = value
          end
        end
      RUBY

      fix!(path)
      fix!(path)

      content = File.read(path)
      expect(content.scan("make_shareable").size).to eq(1)
      expect(content).to include(
        "@backend = (Ractor.make_shareable(value) rescue value)"
      )
      expect(all_findings(path).none?(&:error?)).to be(true)

      script = <<~RUBY
        Warning[:experimental] = false
        require #{path.inspect}
        Config.backend = "file"
        seen = Ractor.new { Config.backend }.value
        raise "not shared" unless seen == "file"
        Config.backend = proc { :cb }
        raise "lost proc" unless Config.backend.call == :cb
        print "best-effort-works"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("best-effort-works"), err
    end
  end

  it "only wraps writes inside actual setter methods" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class Router
          def self.get(path)
            saved = @conditions.dup
            route(path)
            @conditions = saved
          end
        end
      RUBY
      path = write(dir, "router.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "leaves computed setter values alone" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        module Config
          def self.mode=(value)
            @mode = value.to_sym
          end
        end
      RUBY
      path = write(dir, "mode.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "skips constructor memos entirely" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        module Host
          def self.filters = (@filters ||= Set.new)

          def self.instance
            @instance ||= new
          end
        end
      RUBY
      path = write(dir, "ctor.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "keeps Ractor-local conversion off inheritable classes" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class Middleware
          def self.options
            @options ||= defaults.merge(self::EXTRA)
          end

          def self.options=(value)
            @options = value
          end
        end
      RUBY
      path = write(dir, "middleware.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "never converts write-once variables holding constructions" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class Show
          @@eats_errors = Object.new
          def sink = @@eats_errors
        end
      RUBY
      path = write(dir, "eats.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "leaves empty-container accumulators alone" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class Registry
          def self.algorithms = (@algorithms ||= {})

          def self.register(key, value)
            algorithms[key] = value
          end
        end
      RUBY
      path = write(dir, "registry.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
      expect(all_findings(path).any?(&:error?)).to be(true)
    end
  end

  it "never freezes memoized classes" do
    Dir.mktmpdir do |dir|
      path = write(dir, "selector.rb", <<~RUBY)
        class Selector
          def self.pick
            return @pick if defined?(@pick)

            @pick = const_get(:Adapter)
          end

          class Adapter
          end
        end
      RUBY

      fix!(path)

      expect(File.read(path)).to include(
        "@pick = Ractor.make_shareable(const_get(:Adapter))"
      )

      script = <<~RUBY
        require #{path.inspect}
        klass = Selector.pick
        klass.instance_variable_set(:@memo, 1)
        raise "frozen class" if klass.frozen?
        print "class-untouched"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("class-untouched"), err
    end
  end

  it "previews same-line edits as one hunk" do
    Dir.mktmpdir do |dir|
      path = write(dir, "hunk.rb", <<~RUBY)
        $retry_limit = [1, 2, 3]

        def limits = $retry_limit
      RUBY

      previews = Audition::Fixer.new(unsafe: true)
        .preview(all_findings(path))

      first = previews.first[:hunks].first
      expect(first[:new]).to include(
        "RETRY_LIMIT = Ractor.make_shareable([1, 2, 3])"
      )
    end
  end

  it "keeps Ractor storage for initializers with blocks" do
    Dir.mktmpdir do |dir|
      path = write(dir, "loader.rb", <<~RUBY)
        module Host
          def self.loader
            return @loader if defined?(@loader)

            @loader = Struct.new(:x).new(1).tap do |value|
              value.x += 1
            end
          end
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).not_to include("defined?")
      expect(content).to include(<<-RUBY.chomp)
    Ractor.store_if_absent(:"Host/@loader") do
      Struct.new(:x).new(1).tap do |value|
        value.x += 1
      end
    end
      RUBY
      expect(Prism.parse(content).success?).to be(true)
      expect(all_findings(path)).to be_empty
    end
  end

  it "converts a write-once global into a frozen constant" do
    Dir.mktmpdir do |dir|
      path = write(dir, "gvar.rb", <<~RUBY)
        $retry_limit = [1, 2, 3]

        def limits = $retry_limit
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include(
        "RETRY_LIMIT = Ractor.make_shareable([1, 2, 3])"
      )
      expect(content).to include("def limits = RETRY_LIMIT")
      expect(content).not_to include("$retry_limit")
    end
  end

  it "leaves multi-write globals alone" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        $count = 0
        $count = 1
      RUBY
      path = write(dir, "multi.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "refuses conversion when a mutable value gets mutated" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class Mail
          @@autoloads = {}

          def self.register(name, path)
            @@autoloads[name] = path
          end
        end
      RUBY
      path = write(dir, "autoloads.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "converts a write-once class variable into a constant" do
    Dir.mktmpdir do |dir|
      path = write(dir, "cvar.rb", <<~RUBY)
        class Header
          @@maximum = 1000

          def maximum = @@maximum
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include("MAXIMUM = 1000")
      expect(content).to include("def maximum = MAXIMUM")
      expect(content).not_to include("@@maximum")
      expect(Prism.parse(content).success?).to be(true)
    end
  end

  it "converts autoload clusters without breaking load order" do
    Dir.mktmpdir do |dir|
      entry = write(dir, "backend.rb", <<~RUBY)
        module Backend
          autoload :Base,   "base"
          autoload :Helper, "helper"
        end
      RUBY
      write(dir, "base.rb", <<~RUBY)
        module Backend
          module Base
            include Backend::Helper
            OK = "ok"
          end
        end
      RUBY
      write(dir, "helper.rb", <<~RUBY)
        module Backend
          module Helper
          end
        end
      RUBY

      fix!(entry)

      content = File.read(entry)
      expect(content).to include(%(autoload :Base,   "base"))
      expect(content.lines.last(2)).to all(match(/\Arequire "/))
      expect(all_findings(entry)).to be_empty

      script = <<~RUBY
        $LOAD_PATH.unshift(#{dir.inspect})
        require "backend"
        print Backend::Base::OK
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("ok"), err
    end
  end

  it "does nothing at the safe tier" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class Store
          def self.config = (@config ||= compute)
        end
      RUBY
      path = write(dir, "safe.rb", source)

      fix!(path, unsafe: false)

      expect(File.read(path)).to eq(source)
    end
  end

  it "honors an explicit frozen_string_literal: false opt-out" do
    Dir.mktmpdir do |dir|
      path = write(dir, "optout.rb", <<~RUBY)
        # frozen_string_literal: false

        def compute_thing = Object.new

        NAME = "audition"
        DYNAMIC = compute_thing

        def greeting
          text = "hello"
          text << " world"
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).not_to include("frozen_string_literal: true")
      expect(content).to include(%(NAME = "audition".freeze))

      script = <<~RUBY
        require #{path.inspect}
        raise "frozen" unless greeting == "hello world"
        print "opt-out-respected"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("opt-out-respected"), err
    end
  end

  it "inserts no magic comment when only a mutation is flagged" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        Registry::TABLE << :entry
      RUBY
      path = write(dir, "mutation.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "leaves conditionally-written globals alone" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        $strict = true if ENV["STRICT"]

        def strict? = $strict
      RUBY
      path = write(dir, "strict.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "keeps class variables shared with same-file subclasses" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class Parent
          @@default = "unset"

          def value = @@default
        end

        class Child < Parent
          def child_value = @@default
        end
      RUBY
      path = write(dir, "inherit.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)

      script = <<~RUBY
        require #{path.inspect}
        raise "broken" unless Child.new.child_value == "unset"
        print "inheritance-intact"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("inheritance-intact"), err
    end
  end

  it "keeps globals that escape through a local alias" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        $handlers = ["default"]

        def register(handler)
          list = $handlers
          list << handler
        end
      RUBY
      path = write(dir, "handlers.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)

      script = <<~RUBY
        require #{path.inspect}
        register("extra")
        raise "frozen" unless $handlers == ["default", "extra"]
        print "alias-safe"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("alias-safe"), err
    end
  end

  it "skips memo values that contain another converted group" do
    Dir.mktmpdir do |dir|
      path = write(dir, "nested.rb", <<~RUBY)
        module Host
          def self.derived
            @derived ||= [@base]
          end

          def self.base
            @base ||= [1].map { |x| x }
          end
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include(
        'Ractor.store_if_absent(:"Host/@base") ' \
        "{ [1].map { |x| x } }"
      )
      expect(content).to include(
        '@derived ||= [Ractor.current[:"Host/@base"]]'
      )

      script = <<~RUBY
        Warning[:experimental] = false
        require #{path.inspect}
        raise "base" unless Host.base == [1]
        raise "stale" unless Host.derived == [[1]]
        print "nested-intact"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("nested-intact"), err
    end
  end

  it "lets nested global conversions win over enclosing memos" do
    Dir.mktmpdir do |dir|
      path = write(dir, "limits.rb", <<~RUBY)
        $limit = [10]

        module Host
          def self.config
            @config ||= {max: $limit}
          end
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include(
        "LIMIT = Ractor.make_shareable([10])"
      )
      expect(content).to include("@config ||= {max: LIMIT}")
      expect(content).not_to include("$limit")

      script = <<~RUBY
        require #{path.inspect}
        raise "stale" unless Host.config == {max: [10]}
        print "global-intact"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("global-intact"), err
    end
  end

  it "keeps non-guard defined? probes meaningful" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        module Cache
          def self.entries
            @entries ||= [1, 2].map { |x| x * 2 }
          end

          def self.loaded? = defined?(@entries) ? true : false
        end
      RUBY
      path = write(dir, "probe.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)

      script = <<~RUBY
        require #{path.inspect}
        raise "phantom" if Cache.loaded?
        Cache.entries
        raise "missing" unless Cache.loaded?
        print "probe-intact"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("probe-intact"), err
    end
  end

  it "keeps guarded memos whose write is not the method tail" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        module Boot
          def self.setup
            return @setup if defined?(@setup)

            @setup = [1, 2].map { |x| x }
            log_setup
          end

          def self.log_setup = :logged
        end
      RUBY
      path = write(dir, "boot.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "converts guarded writes followed by a bare memo read" do
    Dir.mktmpdir do |dir|
      path = write(dir, "tail.rb", <<~RUBY)
        module Boot
          def self.config
            return @config if defined?(@config)

            @config = [1, 2].map { |x| x }
            @config
          end
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).not_to include("defined?")
      expect(content).to include(
        'Ractor.store_if_absent(:"Boot/@config") ' \
        "{ [1, 2].map { |x| x } }"
      )
      expect(content).to include('Ractor.current[:"Boot/@config"]')

      script = <<~RUBY
        Warning[:experimental] = false
        require #{path.inspect}
        raise "cold" unless Boot.config == [1, 2]
        raise "warm" unless Boot.config == [1, 2]
        print "tail-read-works"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("tail-read-works"), err
    end
  end

  it "keeps instance ivars inside class << self modules alone" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class Api
          def self.token
            @token ||= compute.map { |x| x }
          end

          class << self
            module Helper
              def cache
                @cache ||= calc.map { |x| x }
              end
            end
          end
        end
      RUBY
      path = write(dir, "api.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end

  it "gives colliding constant names to only the first variable" do
    Dir.mktmpdir do |dir|
      path = write(dir, "max.rb", <<~RUBY)
        $max = 10
        $MAX = 20

        def low = $max

        def high = $MAX
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include("MAX = 10")
      expect(content).to include("$MAX = 20")
      expect(content).to include("def high = $MAX")

      script = <<~RUBY
        require #{path.inspect}
        raise "low" unless low == 10
        raise "high" unless high == 20
        print "no-collision"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("no-collision"), err
    end
  end

  it "keeps setter values mutable when mutated via the reader" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        module Config
          def self.options = @options

          def self.options=(value)
            @options = value
          end

          def self.set(key, value)
            options[key] = value
          end
        end
      RUBY
      path = write(dir, "options.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)

      script = <<~RUBY
        require #{path.inspect}
        Config.options = {}
        Config.set(:mode, :fast)
        raise "frozen" unless Config.options == {mode: :fast}
        print "reader-mutation-safe"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("reader-mutation-safe"), err
    end
  end

  it "never wraps operator setter defs" do
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        module Registry
          def self.[]=(key, value)
            @entries = value
          end
        end
      RUBY
      path = write(dir, "brackets.rb", source)

      fix!(path)

      expect(File.read(path)).to eq(source)
    end
  end
end
