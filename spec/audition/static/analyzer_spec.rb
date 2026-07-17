# frozen_string_literal: true

require "tmpdir"

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
        :parallel_analyze, paths, 4
      )

      expect(serial.size).to eq(40)
      expect(parallel.map { |f| [f.location, f.check] })
        .to eq(serial.map { |f| [f.location, f.check] })
    end
  end
end
