# frozen_string_literal: true

require "tmpdir"

RSpec.describe Audition::BundleSweep do
  it "audits every locked gem and ranks the results" do
    Dir.mktmpdir do |dir|
      lock = File.join(dir, "Gemfile.lock")
      File.write(lock, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            multi_json (1.15.0)
            no-such-gem-xyz (1.0.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          multi_json
          no-such-gem-xyz
      LOCK

      rows = described_class.new(
        lockfile: lock, static_only: true
      ).rows

      expect(rows.map(&:name))
        .to contain_exactly("multi_json", "no-such-gem-xyz")

      multi_json = rows.find { |r| r.name == "multi_json" }
      expect(multi_json.verdict).to eq(:not_ready)
      expect(multi_json.errors).to be_positive
      expect(multi_json.status).to eq("ok")

      missing = rows.find { |r| r.name == "no-such-gem-xyz" }
      expect(missing.status).to eq("not installed")
      expect(missing.verdict).to be_nil
    end
  end
end
