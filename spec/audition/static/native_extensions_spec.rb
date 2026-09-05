# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Audition::Static::NativeExtensions do
  def gem_dir
    Dir.mktmpdir("audition") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib/cool_gem"))
      File.write(File.join(dir, "cool_gem.gemspec"), "")
      File.write(File.join(dir, "lib/cool_gem.rb"), "module CoolGem;end\n")
      yield(dir)
    end
  end

  # A stand-in for a Mach-O/ELF file: magic bytes, then the symbol
  # names an extension imports from libruby.
  def compile(dir, imports)
    path = File.join(dir, "lib/cool_gem/cool_gem.bundle")
    header = ["cffaedfe"].pack("H*")
    File.binwrite(path, "#{header}\0_rb_define_method\0#{imports}\0")
    path
  end

  def c_source(dir, body)
    FileUtils.mkdir_p(File.join(dir, "ext/cool_gem"))
    File.write(File.join(dir, "ext/cool_gem/extconf.rb"),
      "require \"mkmf\"\ncreate_makefile(\"cool_gem\")\n")
    path = File.join(dir, "ext/cool_gem/cool_gem.c")
    File.write(path, "#include <ruby.h>\n\nvoid\nInit_cool_gem(void)\n" \
                     "{\n#{body}    rb_define_module(\"CoolGem\");\n}\n")
    path
  end

  def analyze(dir)
    described_class.new.analyze(Audition::Target.detect(dir))
  end

  it "warns about a compiled file that never imports the flag" do
    gem_dir do |dir|
      bundle = compile(dir, "_rb_str_new")

      findings = analyze(dir)

      expect(findings.size).to eq(1)
      finding = findings.first
      expect(finding.check).to eq("native-extension")
      expect(finding.severity).to eq(:warning)
      expect(finding.path).to eq(bundle)
      expect(finding.line).to be_nil
      expect(finding.message).to include("does not declare Ractor safety")
      expect(finding.why).to include("Ractor::UnsafeError")
    end
  end

  it "notes a compiled file that imports rb_ext_ractor_safe" do
    gem_dir do |dir|
      bundle = compile(dir, "_rb_ext_ractor_safe")

      findings = analyze(dir)

      expect(findings.map(&:severity)).to eq([:info])
      expect(findings.first.path).to eq(bundle)
      expect(findings.first.message).to include("declares Ractor safety")
    end
  end

  it "falls back to C sources when nothing is compiled" do
    gem_dir do |dir|
      source = c_source(dir, "")

      findings = analyze(dir)

      expect(findings.map(&:severity)).to eq([:warning])
      expect(findings.first.path).to eq(source)
      expect(findings.first.line).to eq(4)
      expect(findings.first.message).to include("ext/cool_gem")
    end
  end

  it "recognizes the RB_EXT_RACTOR_SAFE macro in C sources" do
    gem_dir do |dir|
      source = c_source(dir, "#ifdef HAVE_RB_EXT_RACTOR_SAFE\n" \
                             "    RB_EXT_RACTOR_SAFE(true);\n#endif\n")

      findings = analyze(dir)

      expect(findings.map(&:severity)).to eq([:info])
      expect(findings.first.path).to eq(source)
      expect(findings.first.line).to eq(7)
    end
  end

  it "recognizes a Rust extension declaring through rb-sys" do
    gem_dir do |dir|
      ext = File.join(dir, "ext/cool_gem")
      FileUtils.mkdir_p(File.join(ext, "src"))
      File.write(File.join(ext, "Cargo.toml"), "[package]\n")
      source = File.join(ext, "src/lib.rs")
      File.write(source, "#[magnus::init]\nfn init() {\n" \
                         "  unsafe { rb_sys::rb_ext_ractor_safe(true) };\n" \
                         "}\n")

      findings = analyze(dir)

      expect(findings.map(&:severity)).to eq([:info])
      expect(findings.first.path).to eq(source)
      expect(findings.first.line).to eq(3)
    end
  end

  it "warns on a Rust extension that never declares" do
    gem_dir do |dir|
      ext = File.join(dir, "ext/cool_gem")
      FileUtils.mkdir_p(File.join(ext, "src"))
      File.write(File.join(ext, "Cargo.toml"), "[package]\n")
      File.write(File.join(ext, "src/lib.rs"),
        "#[magnus::init]\nfn init() {}\n")

      findings = analyze(dir)

      expect(findings.map(&:severity)).to eq([:warning])
      expect(findings.first.path).to eq(File.join(ext, "Cargo.toml"))
    end
  end

  it "trusts the compiled file over the sources" do
    gem_dir do |dir|
      c_source(dir, "    RB_EXT_RACTOR_SAFE(true);\n")
      bundle = compile(dir, "_rb_str_new")

      findings = analyze(dir)

      expect(findings.map(&:severity)).to eq([:warning])
      expect(findings.first.path).to eq(bundle)
    end
  end

  it "reports nothing for a pure-Ruby gem" do
    gem_dir do |dir|
      expect(analyze(dir)).to eq([])
    end
  end
  it "ignores fuzz, bench, and test harness sources" do
    gem_dir do |dir|
      ext = File.join(dir, "ext/cool_gem")
      FileUtils.mkdir_p(File.join(ext, "src"))
      FileUtils.mkdir_p(File.join(ext, "fuzz/src"))
      File.write(File.join(ext, "Cargo.toml"), "[package]\n")
      File.write(File.join(ext, "src/lib.rs"),
        "#[magnus::init]\nfn init() {}\n")
      File.write(File.join(ext, "fuzz/src/lib.rs"),
        "extern \"C\" { fn Init_cool_gem(); }\n" \
        "fn main() { unsafe { rb_ext_ractor_safe(true) } }\n")

      findings = analyze(dir)

      expect(findings.map(&:severity)).to eq([:warning])
      expect(findings.first.path).to eq(File.join(ext, "Cargo.toml"))
    end
  end
end
