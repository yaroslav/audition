# frozen_string_literal: true

RSpec.describe Audition::Static::WorkSplit do
  describe ".workers" do
    def workers(nprocessors:, limit:)
      allow(Etc).to receive(:nprocessors).and_return(nprocessors)
      stub_const("ENV", ENV.to_h.merge("RUBY_MAX_CPU" => limit))
      described_class.workers
    end

    it "uses every core the Ractor pool can run" do
      expect(workers(nprocessors: 4, limit: nil)).to eq(4)
      expect(workers(nprocessors: 32, limit: "24")).to eq(24)
    end

    it "never spawns past the Ractor CPU limit" do
      expect(workers(nprocessors: 32, limit: nil)).to eq(8)
      expect(workers(nprocessors: 32, limit: "4")).to eq(4)
    end

    it "always keeps one worker" do
      expect(workers(nprocessors: 1, limit: "0")).to eq(1)
    end
  end

  describe ".chunks" do
    it "keeps one heavy item from trailing the whole scan" do
      light = 8.times.map { |i| ["light#{i}", 1] }

      chunks = described_class.chunks(light + [["heavy", 500]], 3)

      expect(chunks.size).to eq(3)
      expect(chunks.flatten).to match_array(
        light.map(&:first) + ["heavy"]
      )
      expect(chunks.find { |c| c.include?("heavy") }.size).to eq(1)
    end

    it "leaves no worker idle when items outnumber workers" do
      weighted = 6.times.map { |i| ["f#{i}", i + 1] }

      chunks = described_class.chunks(weighted, 3)

      expect(chunks.map(&:size)).to all(be_positive)
    end

    it "returns one chunk per item when workers outnumber items" do
      chunks = described_class.chunks([["a", 1], ["b", 1]], 8)

      expect(chunks.map(&:size)).to eq([1, 1])
    end

    it "splits equal weights the same way every time" do
      weighted = 10.times.map { |i| ["f#{i}", 10] }

      expect(described_class.chunks(weighted, 4))
        .to eq(described_class.chunks(weighted.shuffle, 4))
    end

    it "balances the load, not the item count" do
      weighted = [["a", 30], ["b", 10], ["c", 10], ["d", 10]]

      chunks = described_class.chunks(weighted, 2)

      expect(chunks).to contain_exactly(["a"], %w[b c d])
    end
  end
end
