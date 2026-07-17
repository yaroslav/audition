# frozen_string_literal: true

require "tmpdir"

RSpec.describe Audition::BundleSweep do
  it "audits every locked gem and ranks the results" do
    Dir.mktmpdir do |dir|
      lock = File.join(dir, "Gemfile.lock")
      # rspec is always installed here: it is running this spec.
      File.write(lock, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rspec (3.13.2)
            no-such-gem-xyz (1.0.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          rspec
          no-such-gem-xyz
      LOCK

      rows = described_class.new(
        lockfile: lock, static_only: true
      ).rows

      expect(rows.map(&:name))
        .to contain_exactly("rspec", "no-such-gem-xyz")

      rspec_row = rows.find { |r| r.name == "rspec" }
      expect(rspec_row.verdict).to eq(:not_ready)
      expect(rspec_row.errors).to be_positive
      expect(rspec_row.status).to eq("ok")

      missing = rows.find { |r| r.name == "no-such-gem-xyz" }
      expect(missing.status).to eq("not installed")
      expect(missing.verdict).to be_nil
    end
  end
end
