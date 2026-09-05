# frozen_string_literal: true

require "tmpdir"

RSpec.describe Audition::Target do
  def in_tmpdir
    Dir.mktmpdir("audition") { |dir| yield(dir) }
  end

  it "detects a .rb file as a script" do
    in_tmpdir do |dir|
      path = File.join(dir, "worker.rb")
      File.write(path, "puts 1\n")

      target = described_class.detect(path)
      expect(target.type).to eq(:script)
      expect(target.ruby_files).to eq([path])
      expect(target.entry).to eq(mode: :script, path: path)
    end
  end

  it "detects a directory with config.ru as a rack app" do
    in_tmpdir do |dir|
      File.write(File.join(dir, "config.ru"), "run ->(e) {}\n")
      File.write(File.join(dir, "app.rb"), "class App; end\n")

      target = described_class.detect(dir)
      expect(target.type).to eq(:rack)
      expect(target.ruby_files).to contain_exactly(
        File.join(dir, "config.ru"), File.join(dir, "app.rb")
      )
      expect(target.entry)
        .to eq(mode: :rack, config_ru: File.join(dir, "config.ru"))
    end
  end

  it "detects a Rails root even when config.ru is present" do
    in_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "config.ru"), "run Rails.application\n")
      File.write(File.join(dir, "config/application.rb"), "module A;end\n")
      File.write(File.join(dir, "app/models/user.rb"), "class User;end\n")

      target = described_class.detect(dir)
      expect(target.type).to eq(:rails)
      expect(target.ruby_files)
        .to include(File.join(dir, "app/models/user.rb"))
      expect(target.entry).to eq(
        mode: :rails,
        environment: File.join(dir, "config/environment.rb"),
        root: dir
      )
    end
  end

  it "detects a directory with a gemspec as a gem" do
    in_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "cool_gem.gemspec"), "")
      File.write(File.join(dir, "lib/cool_gem.rb"), "module CoolGem;end\n")

      target = described_class.detect(dir)
      expect(target.type).to eq(:gem)
      expect(target.entry).to eq(
        mode: :require,
        feature: "cool_gem",
        load_paths: [File.join(dir, "lib")],
        root: dir
      )
    end
  end

  it "resolves an installed gem by name" do
    target = described_class.detect("rubydex")

    expect(target.type).to eq(:gem)
    expect(target.root).to include("rubydex")
    expect(target.entry[:mode]).to eq(:require)
    expect(target.entry[:feature]).to eq("rubydex")
    expect(target.ruby_files).not_to be_empty
  end

  it "treats a plain directory as a static-only target" do
    in_tmpdir do |dir|
      File.write(File.join(dir, "thing.rb"), "X = 1\n")

      target = described_class.detect(dir)
      expect(target.type).to eq(:directory)
      expect(target.entry).to be_nil
    end
  end

  it "skips vendored and hidden trees when globbing" do
    in_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "vendor/bundle"))
      FileUtils.mkdir_p(File.join(dir, "node_modules/x"))
      File.write(File.join(dir, "vendor/bundle/dep.rb"), "Y = 1\n")
      File.write(File.join(dir, "node_modules/x/y.rb"), "Z = 1\n")
      File.write(File.join(dir, "ok.rb"), "X = 1\n")

      target = described_class.detect(dir)
      expect(target.ruby_files).to eq([File.join(dir, "ok.rb")])
    end
  end

  it "treats trailing slashes on relative paths as equivalent" do
    in_tmpdir do |dir|
      app = File.join(dir, "app")
      work = File.join(dir, "work")
      FileUtils.mkdir_p(app)
      FileUtils.mkdir_p(work)
      File.write(File.join(app, "config.ru"), "run ->(e) {}\n")
      File.write(File.join(app, "code.rb"), "X = 1\n")

      Dir.chdir(work) do
        with = described_class.detect("../app/")
        without = described_class.detect("../app")

        expect(with.type).to eq(without.type)
        expect(with.ruby_files).to eq(without.ruby_files)
        expect(with.ruby_files.size).to eq(2)
      end
    end
  end

  it "raises Audition::Error for unknown targets" do
    expect { described_class.detect("definitely-not-a-gem-xyz") }
      .to raise_error(Audition::Error, /not a file, directory/)
  end

  describe ".for_files" do
    it "builds a static-only target from a list of Ruby files" do
      in_tmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "puts 1\n")
        File.write(b, "puts 2\n")

        target = described_class.for_files([a, b])

        expect(target.type).to eq(:files)
        expect(target.ruby_files).to eq([a, b])
        expect(target.entry).to be_nil
        expect(target.root).to eq(Dir.pwd)
      end
    end

    it "rejects a list containing a non-Ruby file" do
      in_tmpdir do |dir|
        rb = File.join(dir, "a.rb")
        md = File.join(dir, "notes.md")
        File.write(rb, "puts 1\n")
        File.write(md, "hi\n")

        expect { described_class.for_files([rb, md]) }
          .to raise_error(Audition::Error, /not a Ruby file/)
      end
    end

    it "rejects a list containing a directory" do
      in_tmpdir do |dir|
        rb = File.join(dir, "a.rb")
        File.write(rb, "puts 1\n")

        expect { described_class.for_files([rb, dir]) }
          .to raise_error(Audition::Error, /not a Ruby file/)
      end
    end
  end
  it "collects compiled extension files, skipping excluded dirs" do
    in_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib/cool_gem"))
      FileUtils.mkdir_p(File.join(dir, "vendor/bundle/x"))
      FileUtils.mkdir_p(File.join(dir, "tmp/x"))
      File.write(File.join(dir, "cool_gem.gemspec"), "")
      File.write(File.join(dir, "lib/cool_gem.rb"), "module CoolGem;end\n")
      bundle = File.join(dir, "lib/cool_gem/cool_gem.bundle")
      File.binwrite(bundle, "\0")
      File.binwrite(File.join(dir, "vendor/bundle/x/dep.so"), "\0")
      File.binwrite(File.join(dir, "tmp/x/build.bundle"), "\0")

      target = described_class.detect(dir)
      expect(target.compiled_files).to eq([bundle])
    end
  end

  it "finds the compiled files of an installed gem by name" do
    target = described_class.detect("rubydex")

    expect(target.compiled_files).not_to be_empty
    expect(target.compiled_files).to all(match(/\.(bundle|so)\z/))
  end

  it "gives scripts no compiled files" do
    in_tmpdir do |dir|
      path = File.join(dir, "worker.rb")
      File.write(path, "puts 1\n")

      expect(described_class.detect(path).compiled_files).to eq([])
    end
  end
  it "ignores debug-symbol copies inside .dSYM bundles" do
    in_tmpdir do |dir|
      dwarf = File.join(dir, "lib/x.bundle.dSYM/Contents/Resources/DWARF")
      FileUtils.mkdir_p(dwarf)
      File.write(File.join(dir, "x.gemspec"), "")
      bundle = File.join(dir, "lib/x.bundle")
      File.binwrite(bundle, "\0")
      File.binwrite(File.join(dwarf, "x.bundle"), "\0")

      expect(described_class.detect(dir).compiled_files).to eq([bundle])
    end
  end
end
