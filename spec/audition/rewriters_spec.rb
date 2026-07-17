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
        TABLES = [[1], [2]].freeze
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content.lines[1])
        .to eq("# shareable_constant_value: literal\n")
      expect(content).to include("CACHE = {}\n")
      expect(content).not_to include("make_shareable")
      expect(all_findings(path)).to be_empty
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

  it "rewrites singleton memoization to Ractor-local storage" do
    Dir.mktmpdir do |dir|
      path = write(dir, "store.rb", <<~RUBY)
        class Store
          def self.config
            @config ||= { "a" => 1 }
          end

          def self.prime
            @config = { "a" => 2 }
          end
        end
      RUBY

      fix!(path)

      content = File.read(path)
      expect(content).to include(
        'Ractor.store_if_absent(:"Store/@config") { { "a" => 1 } }'
      )
      expect(content).to include(
        'Ractor.current[:"Store/@config"] = { "a" => 2 }'
      )

      script = <<~RUBY
        Warning[:experimental] = false
        require #{path.inspect}
        value = Ractor.new { Store.config["a"] }.value
        raise "broken" unless value == 1
        print "works-in-ractor"
      RUBY
      out, err, = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(out).to eq("works-in-ractor"), err
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
end
