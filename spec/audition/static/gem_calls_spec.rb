# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Audition::Static::GemCalls do
  def rule(gem: "fast_widget", namespace: "FastWidget", verified: true)
    described_class::Rule.new(
      gem: gem, namespace: namespace, verified: verified
    )
  end

  def scan(code, rules: [rule])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, code)
      return described_class.new(root: dir, rules: rules)
          .analyze_paths([path])
    end
  end

  # Stubs reach the check from the target, which finds them by
  # extension rather than in a fixed directory.
  def scanner(root)
    described_class.new(root: root,
      stubs: Audition::Target.stubs(root))
  end

  def lockfile(dir, pins)
    specs = pins.map { |p| "    #{p}\n" }.join
    File.write(File.join(dir, "Gemfile.lock"),
      "GEM\n  specs:\n#{specs}")
  end

  def install_fake_gem(base, name:, binary: nil, version: "1.0.0",
    entry: nil, extensions: [])
    full = "#{name}-#{version}"
    lib = File.join(base, "gems", full, "lib")
    entry_path = File.join(lib, "#{name.tr("-", "/")}.rb")
    FileUtils.mkdir_p(File.dirname(entry_path))
    File.write(entry_path,
      entry || "module FastWidget\nend\n")
    File.binwrite(File.join(lib, "#{name}.bundle"), binary) if binary
    spec_dir = File.join(base, "specifications")
    FileUtils.mkdir_p(spec_dir)
    File.write(File.join(spec_dir, "#{full}.gemspec"), <<~RUBY)
      Gem::Specification.new do |s|
        s.name = #{name.inspect}
        s.version = #{version.inspect}
        s.summary = "fake"
        s.authors = ["spec"]
        s.extensions = #{extensions.inspect}
      end
    RUBY
  end

  # One entry per method, each with its own source line, unless
  # shared: is given—the shape a compiled extension leaves. The
  # directory is arbitrary: stubs are found by extension.
  def write_stub(root, name:, methods:, version: "1.0.0",
    shared: nil, dir: "types/generated")
    dir = File.join(root, dir)
    FileUtils.mkdir_p(dir)
    line = 10
    body = methods.map do |owner, names|
      defs = names.map do |method|
        line += 1
        at = shared || line
        "  # source://#{name}//lib/#{name}.rb##{at}\n" \
        "  def #{method}; end\n"
      end.join("\n")
      "class #{owner}\n#{defs}end\n"
    end.join("\n")
    File.write(File.join(dir, "#{name}@#{version}.rbi"),
      "# typed: true\n\n#{body}")
  end

  describe "bundle resolution" do
    it "derives a verified rule from an installed extension " \
       "lacking the declaration" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          install_fake_gem(base, name: "fast_widget",
            binary: "\x00mach\x00")
          lockfile(root, ["fast_widget (1.0.0)"])
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "FastWidget.render(v)\n")

          findings = described_class.new(root: root)
            .analyze_paths([path])
          expect(findings.size).to eq(1)
          expect(findings.first).to have_attributes(
            check: "native-gem-calls", severity: :warning, line: 1
          )
          expect(findings.first.message)
            .to include("does not declare Ractor safety")
          expect(findings.first.why).to include("Ractor::UnsafeError")
        end
      end
    end

    it "drops gems whose extension declares safety" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          install_fake_gem(base, name: "fast_widget",
            binary: "\x00rb_ext_ractor_safe\x00")
          lockfile(root, ["fast_widget (1.0.0)"])
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "FastWidget.render(v)\n")

          expect(described_class.new(root: root).analyze_paths([path]))
            .to be_empty
        end
      end
    end

    it "reads the namespace from the entry file's module nesting" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          install_fake_gem(base, name: "fast_widget", binary: "\x00",
            entry: "require \"json\"\n" \
                   "module Fast\n" \
                   "  module WidgetCore\n" \
                   "    VERSION = \"1\"\n" \
                   "  end\n" \
                   "end\n")
          lockfile(root, ["fast_widget (1.0.0)"])
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "Fast::WidgetCore.render(v)\n" \
                           "FastWidget.render(v)\n")

          findings = described_class.new(root: root)
            .analyze_paths([path])
          expect(findings.map(&:line)).to contain_exactly(1)
        end
      end
    end

    it "flags platform-pinned gems it cannot inspect as unverified" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          lockfile(root, ["fast_widget (1.0.0-arm64-darwin)",
            "fast_widget (1.0.0-x86_64-linux-gnu)"])
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "FastWidget.render(v)\n")

          findings = described_class.new(root: root)
            .analyze_paths([path])
          expect(findings.size).to eq(1)
          expect(findings.first.message).to include("could not inspect")
          expect(findings.first.why).to include("install the bundle")
        end
      end
    end

    it "settles a spec with no readable binary against Ruby's " \
       "own extension" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          Dir.mktmpdir do |archdir|
            install_fake_gem(base, name: "fast_widget",
              extensions: ["ext/fast_widget/extconf.rb"])
            File.binwrite(File.join(archdir, "fast_widget.bundle"),
              "\x00rb_ext_ractor_safe\x00")
            lockfile(root, ["fast_widget (1.0.0)"])
            allow(Gem).to receive(:path).and_return([base])
            allow(RbConfig::CONFIG).to receive(:[]).and_call_original
            allow(RbConfig::CONFIG).to receive(:[]).with("archdir")
              .and_return(archdir)
            path = File.join(root, "a.rb")
            File.write(path, "FastWidget.render(v)\n")

            expect(described_class.new(root: root)
              .analyze_paths([path])).to be_empty
          end
        end
      end
    end

    it "clears a platform pin when Ruby's own extension declares " \
       "safety" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          Dir.mktmpdir do |archdir|
            File.binwrite(File.join(archdir, "fast_widget.bundle"),
              "\x00rb_ext_ractor_safe\x00")
            lockfile(root, ["fast_widget (1.0.0-arm64-darwin)"])
            allow(Gem).to receive(:path).and_return([base])
            allow(RbConfig::CONFIG).to receive(:[]).and_call_original
            allow(RbConfig::CONFIG).to receive(:[]).with("archdir")
              .and_return(archdir)
            path = File.join(root, "a.rb")
            File.write(path, "FastWidget.render(v)\n")

            expect(described_class.new(root: root)
              .analyze_paths([path])).to be_empty
          end
        end
      end
    end

    it "verifies a platform pin against Ruby's own extension when " \
       "it lacks the declaration" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          Dir.mktmpdir do |archdir|
            File.binwrite(File.join(archdir, "fast_widget.bundle"),
              "\x00mach\x00")
            lockfile(root, ["fast_widget (1.0.0-arm64-darwin)"])
            allow(Gem).to receive(:path).and_return([base])
            allow(RbConfig::CONFIG).to receive(:[]).and_call_original
            allow(RbConfig::CONFIG).to receive(:[]).with("archdir")
              .and_return(archdir)
            path = File.join(root, "a.rb")
            File.write(path, "FastWidget.render(v)\n")

            findings = described_class.new(root: root)
              .analyze_paths([path])
            expect(findings.size).to eq(1)
            expect(findings.first.message)
              .to include("does not declare Ractor safety")
          end
        end
      end
    end

    it "ignores pure-Ruby pins and gems it knows nothing about" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          lockfile(root, ["plainlib (1.0.0)"])
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "Plainlib.run(v)\n")

          expect(described_class.new(root: root).analyze_paths([path]))
            .to be_empty
        end
      end
    end

    it "reads compiled evidence from a generated type stub" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          lockfile(root, ["fast_widget (1.0.0)"])
          write_stub(root, name: "fast_widget", shared: 17,
            methods: {"Fast::Widget" => %w[render parse],
                      "Fast::Widget::Doc" => %w[items first]})
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "Fast::Widget.render(v)\n" \
                           "Fast::Other.render(v)\n")

          findings = scanner(root).analyze_paths([path])
          expect(findings.map(&:line)).to contain_exactly(1)
          expect(findings.first.message)
            .to include("could not inspect")
        end
      end
    end

    it "ignores a stub whose methods are Ruby-defined" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          lockfile(root, ["fast_widget (1.0.0)"])
          write_stub(root, name: "fast_widget",
            methods: {"Fast::Widget" => %w[render parse],
                      "Fast::Widget::Doc" => %w[items first]})
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "Fast::Widget.render(v)\n")

          expect(scanner(root).analyze_paths([path])).to be_empty
        end
      end
    end

    it "ignores a stub cluster owned by a single class" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          lockfile(root, ["fast_widget (1.0.0)"])
          write_stub(root, name: "fast_widget", shared: 17,
            methods: {"Fast::Widget" => %w[render parse items]})
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "Fast::Widget.render(v)\n")

          expect(scanner(root).analyze_paths([path])).to be_empty
        end
      end
    end

    it "adds stub namespaces to a platform pin's own name" do
      Dir.mktmpdir do |base|
        Dir.mktmpdir do |root|
          lockfile(root, ["fast_widget (1.0.0-arm64-darwin)"])
          write_stub(root, name: "fast_widget", shared: 17,
            methods: {"Fast::Widget" => %w[render parse],
                      "Fast::Widget::Doc" => %w[items first]})
          allow(Gem).to receive(:path).and_return([base])
          path = File.join(root, "a.rb")
          File.write(path, "FastWidget.render(v)\n" \
                           "Fast::Widget::Doc.items\n")

          findings = scanner(root).analyze_paths([path])
          expect(findings.map(&:line)).to contain_exactly(1, 2)
        end
      end
    end

    it "returns nothing without a lockfile" do
      Dir.mktmpdir do |root|
        path = File.join(root, "a.rb")
        File.write(path, "FastWidget.render(v)\n")

        expect(described_class.new(root: root).analyze_paths([path]))
          .to be_empty
      end
    end
  end

  it "flags calls anywhere under the gem's namespace" do
    findings = scan(
      "FastWidget.parse(v)\n" \
      "FastWidget::HTML::Document.parse(v)\n"
    )

    expect(findings.map(&:line)).to contain_exactly(1, 2)
    expect(findings.first.fix).to include("main Ractor")
  end

  it "leaves lookalike receivers alone" do
    findings = scan(
      "FastWidgetry.parse(v)\n" \
      "Acme::FastWidget.parse(v)\n" \
      "registry.parse(v)\n"
    )

    expect(findings).to be_empty
  end

  it "skips core Object methods on the namespace" do
    findings = scan("FastWidget.respond_to?(:parse)\n")

    expect(findings).to be_empty
  end

  it "follows a gem object through the local it is assigned to" do
    findings = scan(
      "doc = FastWidget.parse(markup)\n" \
      "doc.items\n" \
      "doc.nil?\n" \
      "doc if doc.frozen?\n"
    )

    expect(findings.map(&:line)).to contain_exactly(1, 2)
    derived = findings.find { |f| f.line == 2 }
    expect(derived.message).to include("items")
    expect(derived.message).to include("handed out")
  end

  it "drops the taint when the local is reassigned" do
    findings = scan(
      "doc = FastWidget.parse(markup)\n" \
      "doc = plain\n" \
      "doc.items\n"
    )

    expect(findings.map(&:line)).to contain_exactly(1)
  end

  it "keeps taint out of other method scopes" do
    findings = scan(
      "doc = FastWidget.parse(markup)\n" \
      "def render(doc)\n" \
      "  doc.items\n" \
      "end\n"
    )

    expect(findings.map(&:line)).to contain_exactly(1)
  end

  it "follows a syntactic chain rooted in the namespace" do
    findings = scan(
      "klass = FastWidget.pool\n" \
      "  .lookup(\"w\").msgclass\n" \
      "klass.decode(bytes)\n"
    )

    methods = findings.map { |f| f.message[/\A\w+/] }
    expect(methods).to include("lookup", "msgclass", "decode")
    decode = findings.find { |f| f.message.start_with?("decode") }
    expect(decode.line).to eq(3)
  end

  it "follows the taint through a local hop" do
    findings = scan(
      "doc = FastWidget.parse(markup)\n" \
      "items = doc.items\n" \
      "items.push(v)\n"
    )

    expect(findings.map(&:line)).to contain_exactly(1, 2, 3)
  end

  it "stops the chain at a predicate" do
    findings = scan(
      "doc = FastWidget.parse(markup)\n" \
      "ok = doc.valid?\n" \
      "ok.inspect\n"
    )

    expect(findings.map(&:line)).to contain_exactly(1, 2)
  end

  it "passes the taint through class, freeze, and tap silently" do
    findings = scan(
      "doc = FastWidget.parse(markup)\n" \
      "doc.class.descriptor\n" \
      "doc.freeze.items\n"
    )

    expect(findings.map(&:line)).to contain_exactly(1, 2, 3)
    methods = findings.map { |f| f.message[/\A\w+/] }
    expect(methods).to include("descriptor", "items")
    expect(methods).not_to include("class", "freeze")
  end

  it "flags the chained call on its own line" do
    findings = scan(
      "class Widget\n" \
      "  def initialize\n" \
      "    @raw = FastWidget::Codec.decode(data)\n" \
      "  end\n" \
      "  def names\n" \
      "    @raw.fetch(:names)\n" \
      "      .map { |v| v.to_sym }\n" \
      "  end\n" \
      "end\n"
    )

    expect(findings.map(&:line).uniq).to contain_exactly(3, 6, 7)
  end

  it "taints params typed under the namespace in a sig" do
    findings = scan(
      "sig { params(doc: FastWidget::Document, n: Integer).void }\n" \
      "def render(doc, n)\n" \
      "  doc.items\n" \
      "  n.to_s\n" \
      "end\n"
    )

    expect(findings.map(&:line)).to contain_exactly(3)
  end

  it "taints locals annotated with T.let under the namespace" do
    findings = scan(
      "doc = T.let(fetch_doc, T.nilable(FastWidget::Document))\n" \
      "doc.items\n"
    )

    expect(findings.map(&:line)).to contain_exactly(2)
  end

  it "clears the taint when T.let names a plain type" do
    findings = scan(
      "s = T.let(FastWidget.render(v), String)\n" \
      "s.length\n"
    )

    expect(findings.map(&:line)).to contain_exactly(1)
  end

  it "carries taint through ivars across methods" do
    findings = scan(
      "class Renderer\n" \
      "  def initialize(markup)\n" \
      "    @doc = FastWidget.parse(markup)\n" \
      "  end\n" \
      "\n" \
      "  def links\n" \
      "    @doc.items\n" \
      "  end\n" \
      "end\n"
    )

    expect(findings.map(&:line)).to contain_exactly(3, 7)
  end

  it "carries taint into a local copied from an ivar" do
    findings = scan(
      "class Renderer\n" \
      "  def initialize(markup)\n" \
      "    @doc = FastWidget.parse(markup)\n" \
      "  end\n" \
      "\n" \
      "  def links\n" \
      "    doc = @doc\n" \
      "    doc.items\n" \
      "  end\n" \
      "end\n"
    )

    expect(findings.map(&:line)).to contain_exactly(3, 8)
  end

  it "hands a tainted receiver to a then block" do
    findings = scan(<<~RUBY)
      doc = FastWidget.parse(markup)
      doc.then { |d| d.items }
    RUBY

    expect(findings.map(&:line)).to contain_exactly(1, 2)
  end

  it "keeps taint one branch introduces past the branch" do
    findings = scan(<<~RUBY)
      if native?
        doc = FastWidget.parse(markup)
      else
        doc = plain_parse(markup)
      end
      doc.items
    RUBY

    expect(findings.map(&:line)).to contain_exactly(2, 6)
  end

  it "drops taint every branch replaces" do
    findings = scan(<<~RUBY)
      doc = FastWidget.parse(markup)
      if native?
        doc = plain_parse(markup)
      else
        doc = other_parse(markup)
      end
      doc.items
    RUBY

    expect(findings.map(&:line)).to contain_exactly(1)
  end

  it "skips unparseable files" do
    findings = scan("def broken(\n")

    expect(findings).to be_empty
  end

  describe "block parameters" do
    it "taints block parameters of a call on a tainted receiver" do
      findings = scan(<<~RUBY)
        doc = FastWidget.parse(markup)
        names = doc.items.map do |item|
          item.label
        end
        names.first
      RUBY

      label = findings.find { |f| f.message.start_with?("label") }
      expect(label&.line).to eq(3)
    end

    it "drops the block taint after the block" do
      findings = scan(<<~RUBY)
        item = plain
        doc = FastWidget.parse(markup)
        doc.items.each do |item|
          item.label
        end
        item.label
      RUBY

      expect(findings.map(&:line).uniq).to contain_exactly(2, 3, 4)
    end

    it "keeps the memo parameter of each_with_object clean" do
      findings = scan(<<~RUBY)
        doc = FastWidget.parse(markup)
        doc.fields.each_with_object({}) do |field, acc|
          acc.store(field.key, 1)
        end
      RUBY

      methods = findings.map { |f| f.message[/\A[\w?]+/] }
      expect(methods).to include("key")
      expect(methods).not_to include("store")
    end

    it "taints block parameters of a predicate iterator" do
      findings = scan(<<~RUBY)
        doc = FastWidget.parse(markup)
        ok = doc.items.any? { |item| item.valid? }
        ok.inspect
      RUBY

      expect(findings.map(&:line).uniq).to contain_exactly(1, 2)
      methods = findings.map { |f| f.message[/\A[\w?]+/] }
      expect(methods).to include("valid?")
    end

    it "taints numbered block parameters" do
      findings = scan(
        "doc = FastWidget.parse(markup)\n" \
        "doc.items.each { _1.label }\n"
      )

      methods = findings.map { |f| f.message[/\A[\w?]+/] }
      expect(methods).to include("label")
    end

    it "taints destructured block parameters" do
      findings = scan(<<~RUBY)
        doc = FastWidget.parse(markup)
        doc.entries.each do |(key, val)|
          val.pack
        end
      RUBY

      methods = findings.map { |f| f.message[/\A[\w?]+/] }
      expect(methods).to include("pack")
    end

    it "leaves blocks on plain calls alone" do
      findings = scan("rows.each { |row| row.save }\n")

      expect(findings).to be_empty
    end
  end

  describe "argument taint" do
    it "seeds a callee parameter from a tainted argument" do
      findings = scan(<<~RUBY)
        class Report
          sig { params(widget: FastWidget::Row).void }
          def handle(widget)
            errors = widget.errors
            log(errors)
          end

          sig { params(errors: T::Array[T.untyped]).void }
          def log(errors)
            errors.each do |error|
              error.message
            end
          end
        end
      RUBY

      expect(findings.map(&:line).uniq).to include(10, 11)
    end

    it "keeps a plainly typed parameter clean" do
      findings = scan(<<~RUBY)
        class Report
          sig { params(widget: FastWidget::Row).void }
          def handle(widget)
            errors = widget.errors
            log(errors)
          end

          sig { params(errors: String).void }
          def log(errors)
            errors.chars
          end
        end
      RUBY

      expect(findings.map(&:line).uniq).to contain_exactly(4)
    end

    it "carries a computed return into callers above the def" do
      findings = scan(<<~RUBY)
        class Report
          sig { params(widget: FastWidget::Row).void }
          def handle(widget)
            errors = collect(widget)
            errors.first.message
          end

          def collect(widget)
            rows = widget.rows
            rows + extra
          end
        end
      RUBY

      expect(findings.map(&:line).uniq).to include(5, 9, 10)
    end

    it "seeds keyword parameters" do
      findings = scan(<<~RUBY)
        class Report
          sig { params(widget: FastWidget::Row).void }
          def handle(widget)
            log(errors: widget.errors)
          end

          def log(errors: nil)
            errors.message
          end
        end
      RUBY

      expect(findings.map(&:line).uniq).to include(4, 8)
    end

    it "keeps seeds inside their own class" do
      findings = scan(<<~RUBY)
        class Alpha
          sig { params(widget: FastWidget::Row).void }
          def handle(widget)
            log(widget.errors)
          end

          def log(errors)
            errors.message
          end
        end

        class Beta
          def log(errors)
            errors.message
          end
        end
      RUBY

      expect(findings.map(&:line).uniq).to contain_exactly(4, 8)
    end

    it "seeds through a call on the defining module's name" do
      findings = scan(<<~RUBY)
        module Packer
          def self.pack(widget)
            widget.errors
          end
        end

        Packer.pack(FastWidget::Row.new)
      RUBY

      expect(findings.map(&:line).uniq).to contain_exactly(3, 7)
    end

    it "reaches an instance method a module extended itself with" do
      findings = scan(<<~RUBY)
        module Packer
          extend self

          def pack(widget)
            widget.errors
          end
        end

        Packer.pack(FastWidget::Row.new)
      RUBY

      expect(findings.map(&:line).uniq).to contain_exactly(5, 9)
    end

    it "keeps an instance method the module never exposed clean" do
      findings = scan(<<~RUBY)
        module Packer
          def pack(widget)
            widget.errors
          end
        end

        Packer.pack(FastWidget::Row.new)
      RUBY

      expect(findings.map(&:line).uniq).to contain_exactly(7)
    end
  end

  describe "type narrowing" do
    it "taints the subject inside a matching when branch" do
      findings = scan(<<~RUBY)
        def visit(node)
          case node
          when FastWidget::Row
            node.cells
          when Integer
            node.succ
          end
        end
      RUBY

      expect(findings.map(&:line)).to contain_exactly(4)
    end

    it "covers the else clause when every branch matches the rule" do
      findings = scan(<<~RUBY)
        def visit(node)
          case node
          when FastWidget::Row
            node.cells
          when FastWidget::Col
            node.rows
          else
            node.val
          end
        end
      RUBY

      expect(findings.map(&:line)).to contain_exactly(4, 6, 8)
    end

    it "leaves the else clause alone on mixed branches" do
      findings = scan(<<~RUBY)
        def visit(node)
          case node
          when FastWidget::Row
            node.cells
          when Integer
            node.succ
          else
            node.val
          end
        end
      RUBY

      expect(findings.map(&:line)).to contain_exactly(4)
    end

    it "makes a case handing the subject back a producer" do
      findings = scan(<<~RUBY)
        def unwrap(node)
          ref = case node
          when FastWidget::Row then node
          when FastWidget::Node then node.row if deep
          end
          ref.cells
        end
      RUBY

      expect(findings.map(&:line)).to contain_exactly(4, 6)
    end

    it "taints a variable proven by an is_a? guard" do
      findings = scan(<<~RUBY)
        def unwrap(node)
          return node unless node.is_a?(FastWidget::Node)

          node.fields
        end
      RUBY

      expect(findings.map(&:line)).to contain_exactly(4)
    end

    it "taints inside an is_a? conditional body only" do
      findings = scan(<<~RUBY)
        def visit(node)
          if node.is_a?(FastWidget::Node) && node.val
            node.fields
          else
            node.entries
          end
          node.items
        end
      RUBY

      expect(findings.map(&:line)).to contain_exactly(3)
    end

    it "ignores guards that do not bail" do
      findings = scan(<<~RUBY)
        def visit(node)
          log unless node.is_a?(FastWidget::Node)
          node.fields
        end
      RUBY

      expect(findings).to be_empty
    end

    it "ignores type checks against plain constants" do
      findings = scan(<<~RUBY)
        def visit(node)
          return unless node.is_a?(Widget)

          node.fields
        end
      RUBY

      expect(findings).to be_empty
    end
  end

  describe "class-body registry" do
    it "taints callers of a memoized factory defined below them" do
      findings = scan(<<~RUBY)
        class Widget
          def initialize
            @raw = Widget.native_class.new
          end

          def id
            @raw["id"]
          end

          def id=(value)
            @raw["id"] = value
          end

          class << self
            def native_class
              @native_class ||= FastWidget::Pool.pool.lookup("w")
            end
          end
        end
      RUBY

      expect(findings.map(&:line)).to include(3, 7, 11, 16)
      deref = findings.find { |f| f.line == 7 }
      expect(deref.message).to include("handed out")
    end

    it "reaches the singleton through self.class and bare calls" do
      findings = scan(<<~RUBY)
        class Widget
          def native_class
            self.class.native_class
          end

          def dup_native
            native_class.new
          end

          def self.native_class
            FastWidget::Pool.lookup("w")
          end
        end
      RUBY

      expect(findings.map(&:line)).to include(7, 11)
    end

    it "taints an ivar assigned through its attr writer" do
      findings = scan(<<~RUBY)
        class Widget
          attr_writer :raw

          def field
            @raw["f"]
          end

          def self.decode(data)
            widget = new
            widget.raw = FastWidget::Codec.decode(data)
            widget
          end
        end
      RUBY

      expect(findings.map(&:line)).to include(5, 10)
    end

    it "hands taint out through an attr reader over a tainted ivar" do
      findings = scan(<<~RUBY)
        class Widget
          attr_reader :raw

          def initialize
            @raw = FastWidget::Codec.decode("x")
          end

          def field
            raw.field("f")
          end
        end
      RUBY

      expect(findings.map(&:line)).to include(5, 9)
    end

    it "taints a method whose sig returns a namespace type" do
      findings = scan(<<~RUBY)
        class Widget
          sig { returns(FastWidget::Blob) }
          def blob
            fetch_blob
          end

          def use
            blob.compress
          end
        end
      RUBY

      expect(findings.map(&:line)).to contain_exactly(8)
    end

    it "leaves plain methods and sibling classes alone" do
      findings = scan(<<~RUBY)
        class Widget
          def self.native_class
            FastWidget::Pool.lookup("w")
          end
        end

        class Gadget
          def initialize
            @raw = Gadget.native_class.new
          end

          def builder
            Builder.new
          end

          def use
            builder.build
            @raw["f"]
          end
        end
      RUBY

      expect(findings.map(&:line)).to contain_exactly(3)
    end
  end

  describe "cross-file promotion" do
    def scan_files(files, rules: [rule])
      Dir.mktmpdir do |dir|
        paths = files.map.with_index do |code, i|
          path = File.join(dir, "f#{i}.rb")
          File.write(path, code)
          path
        end
        return described_class.new(root: dir, rules: rules)
            .analyze_paths(paths)
            .group_by { |f| File.basename(f.path) }
      end
    end

    it "promotes a class holding extension values to a rule" do
      wrapper = <<~RUBY
        module Kit
          class Widget
            def initialize(data)
              @raw = FastWidget::Codec.decode(data)
            end
          end
        end
      RUBY
      caller_file = <<~RUBY
        widget = Kit::Widget.new(data)
        widget.pack
      RUBY

      findings = scan_files([wrapper, caller_file])

      expect(findings["f1.rb"].map(&:line)).to contain_exactly(1, 2)
    end

    it "taints params typed with a promoted class in a sig" do
      wrapper = <<~RUBY
        module Kit
          class Widget
            def initialize(data)
              @raw = FastWidget::Codec.decode(data)
            end
          end
        end
      RUBY
      caller_file = <<~RUBY
        sig { params(widget: Kit::Widget).void }
        def read(widget)
          widget.fields
        end
      RUBY

      findings = scan_files([wrapper, caller_file])

      expect(findings["f1.rb"].map(&:line)).to contain_exactly(3)
    end

    it "promotes subclasses of a promoted class" do
      wrapper = <<~RUBY
        module Kit
          class Widget
            def initialize(data)
              @raw = FastWidget::Codec.decode(data)
            end
          end

          class Gadget < Widget
          end
        end
      RUBY
      caller_file = "Kit::Gadget.new(data)\n"

      findings = scan_files([wrapper, caller_file])

      expect(findings["f1.rb"].map(&:line)).to contain_exactly(1)
    end

    it "promotes constants bound to extension-rooted values" do
      binding_file = <<~RUBY
        module Kit
          Widget = FastWidget::Pool.generated.lookup("w").msgclass
          Widget::Inner = FastWidget::Pool.generated.lookup("wi").msgclass
        end
      RUBY
      caller_file = <<~RUBY
        message = Kit::Widget.decode(data)
        message.id
        Kit::Widget::Inner.new(a: 1)
      RUBY

      findings = scan_files([binding_file, caller_file])

      expect(findings["f1.rb"].map(&:line)).to contain_exactly(1, 2, 3)
    end

    it "resolves a promoted name through the lexical nesting" do
      binding_file = <<~RUBY
        module Kit
          Widget = FastWidget::Pool.generated.lookup("w").msgclass
        end
      RUBY
      caller_file = <<~RUBY
        module Kit
          class Builder
            def build
              Widget.new(a: 1)
            end
          end
        end
      RUBY

      findings = scan_files([binding_file, caller_file])

      expect(findings["f1.rb"].map(&:line)).to contain_exactly(4)
    end

    it "keeps an anchored path out of the nesting" do
      binding_file = <<~RUBY
        module Kit
          Widget = FastWidget::Pool.generated.lookup("w").msgclass
        end
      RUBY
      caller_file = <<~RUBY
        module Kit
          def self.build = ::Widget.new
        end
      RUBY

      findings = scan_files([binding_file, caller_file])

      expect(findings["f1.rb"]).to be_nil
    end

    it "flags self-calls in a class_eval reopening of a bound name" do
      binding_file = <<~RUBY
        module Kit
          Widget = FastWidget::Pool.generated.lookup("w").msgclass
        end
      RUBY
      wrapper_file = <<~RUBY
        module Kit
          Widget.class_eval do
            def to_ruby
              case self.kind
              when :list_value then self.list_value
              else self.helper
              end
            end

            def helper = 1
          end
        end
      RUBY

      findings = scan_files([binding_file, wrapper_file])

      expect(findings["f1.rb"].map(&:line)).to contain_exactly(4, 5)
    end

    it "flags self-calls when a bound class is reopened by name" do
      binding_file = <<~RUBY
        module Kit
          Widget = FastWidget::Pool.generated.lookup("w").msgclass
        end
      RUBY
      wrapper_file = <<~RUBY
        module Kit
          class Widget
            def self.from_hash(hash)
              self.new(hash)
            end
          end
        end
      RUBY

      findings = scan_files([binding_file, wrapper_file])

      expect(findings["f1.rb"].map(&:line)).to contain_exactly(4)
    end

    it "flags bare argumentless calls in a bound reopening" do
      binding_file = <<~RUBY
        module Kit
          Widget = FastWidget::Pool.generated.lookup("w").msgclass
        end
      RUBY
      wrapper_file = <<~RUBY
        module Kit
          Widget.class_eval do
            def to_h
              fields.each_with_object({}) do |field, acc|
                acc[field.key] = field.val
              end
            end

            def helper = 1

            def wrapped = helper

            def show = inspect
          end
        end
      RUBY

      findings = scan_files([binding_file, wrapper_file])

      expect(findings["f1.rb"].map(&:line).uniq).to contain_exactly(4, 5)
    end

    it "leaves self-calls in merely promoted classes alone" do
      holder_file = <<~RUBY
        class Renderer
          def initialize(markup)
            @doc = FastWidget.parse(markup)
          end

          def render
            self.finish
          end
        end
      RUBY

      findings = scan_files([holder_file])

      expect(findings["f0.rb"].map(&:line)).to contain_exactly(3)
    end

    it "leaves classes without extension values alone" do
      plain = <<~RUBY
        module Kit
          class Clean
            def initialize(data)
              @data = data
            end
          end
        end
      RUBY
      caller_file = "Kit::Clean.new(data).pack\n"

      findings = scan_files([plain, caller_file])

      expect(findings["f1.rb"]).to be_nil
    end

    it "seeds a parameter from a call in another file" do
      def_file = <<~RUBY
        module Packer
          def self.pack(widget)
            widget.errors
          end
        end
      RUBY
      caller_file = "Packer.pack(FastWidget::Row.new)\n"

      findings = scan_files([def_file, caller_file])

      expect(findings["f0.rb"].map(&:line)).to contain_exactly(3)
    end

    it "seeds a parameter from a call in an earlier file" do
      caller_file = "Packer.pack(FastWidget::Row.new)\n"
      def_file = <<~RUBY
        module Packer
          def self.pack(widget)
            widget.errors
          end
        end
      RUBY

      findings = scan_files([caller_file, def_file])

      expect(findings["f1.rb"].map(&:line)).to contain_exactly(3)
    end

    it "binds self in a module prepended to a bound class" do
      binding_file = <<~RUBY
        module Kit
          Widget = FastWidget::Pool.generated.lookup("w").msgclass
        end
      RUBY
      mixin_file = <<~RUBY
        module Helper
          def keys
            fields.map(&:key)
          end
        end

        Kit::Widget.prepend(Helper)
      RUBY

      findings = scan_files([binding_file, mixin_file])

      expect(findings["f1.rb"].map(&:line)).to include(3)
    end

    it "binds self in a module a bound class extends" do
      binding_file = <<~RUBY
        module Kit
          Widget = FastWidget::Pool.generated.lookup("w").msgclass
        end
      RUBY
      mixin_file = <<~RUBY
        module Builder
          def from_hash(hash)
            Packer.pack(self)
          end
        end

        Kit::Widget.extend(Builder)
      RUBY
      def_file = <<~RUBY
        module Packer
          def self.pack(widget)
            widget.errors
          end
        end
      RUBY

      findings = scan_files([binding_file, mixin_file, def_file])

      expect(findings["f2.rb"].map(&:line)).to contain_exactly(3)
    end

    it "leaves a module mixed into a plain class alone" do
      plain_file = <<~RUBY
        module Helper
          def keys
            fields.map(&:key)
          end
        end

        Kit::Clean.include(Helper)
      RUBY

      findings = scan_files([plain_file])

      expect(findings["f0.rb"]).to be_nil
    end
  end
end
