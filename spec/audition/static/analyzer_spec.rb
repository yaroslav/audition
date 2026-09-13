# frozen_string_literal: true

require "tmpdir"
require "stringio"

RSpec.describe Audition::Static::Analyzer do
  it "produces identical findings in serial and parallel" do
    Dir.mktmpdir do |dir|
      paths = 20.times.map do |i|
        path = File.join(dir, "file#{format("%02d", i)}.rb")
        File.write(path,
          "$gvar#{i} = #{i}\nCACHE#{i} = {}\nfoo(#{i})\n")
        path
      end

      serial = described_class.new.analyze_paths(
        paths, workers: 1
      )
      # Called directly so a broken Ractor path raises instead of
      # being masked by the serial fallback.
      parallel = described_class.new.send(
        :parallel_analyze, paths, 4, Audition::Progress::SILENT
      )

      expect(serial.size).to eq(40)
      # Chunks are packed by size, so the concatenation order is
      # the scheduler's; the report sorts before anyone reads it.
      expect(parallel.map { |f| [f.location, f.check] }.sort)
        .to eq(serial.map { |f| [f.location, f.check] }.sort)
    end
  end

  it "narrates the Ractor count it is scanning on" do
    Dir.mktmpdir do |dir|
      paths = 4.times.map do |i|
        path = File.join(dir, "f#{i}.rb")
        File.write(path, "X#{i} = {}\n")
        path
      end
      progress = Audition::Progress.new(
        renderer: Audition::Progress::Renderer.new(StringIO.new)
      )

      described_class.new.send(
        :parallel_analyze, paths, 2, progress
      )

      expect(progress.ractors).to eq(2)
    end
  end

  # The split itself is WorkSplit's; this is the weight the
  # Analyzer gives it.
  describe "#balanced_chunks" do
    it "weighs files by size and isolates the heaviest" do
      Dir.mktmpdir do |dir|
        heavy = File.join(dir, "heavy.rb")
        File.write(heavy, "# padding\n" * 5_000)
        light = 8.times.map do |i|
          path = File.join(dir, "light#{i}.rb")
          File.write(path, "X = #{i}\n")
          path
        end

        chunks = described_class.new.send(
          :balanced_chunks, light + [heavy], 3
        )

        expect(chunks.size).to eq(3)
        expect(chunks.flatten).to match_array(light + [heavy])
        expect(chunks.find { |c| c.include?(heavy) }.size).to eq(1)
      end
    end

    it "weighs a file it cannot stat as nothing" do
      chunks = described_class.new.send(
        :balanced_chunks, ["/nonexistent/gone.rb"], 2
      )

      expect(chunks).to eq([["/nonexistent/gone.rb"]])
    end
  end
end
