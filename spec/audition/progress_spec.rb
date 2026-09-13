# frozen_string_literal: true

require "stringio"

RSpec.describe Audition::Progress do
  let(:plain) do
    Audition::Report::Style.new(color: false, hyperlinks: false)
  end

  def terminal
    io = StringIO.new
    allow(io).to receive(:tty?).and_return(true)
    io
  end

  # Zero interval so every update leaves a frame to assert on.
  def line(io)
    described_class.new(
      renderer: described_class::Line.new(io, style: plain,
        interval: 0)
    )
  end

  def log(io)
    described_class.new(
      renderer: described_class::Log.new(io, style: plain)
    )
  end

  describe ".for" do
    it "stays silent below the auto threshold" do
      expect(described_class.for(units: 10, io: terminal))
        .not_to be_enabled
    end

    it "stays silent when the stream is not a terminal" do
      expect(described_class.for(units: 10_000, io: StringIO.new))
        .not_to be_enabled
    end

    it "stays silent for machine-readable formats" do
      io = terminal

      %i[json github].each do |format|
        expect(described_class.for(units: 10_000, format: format,
          io: io)).not_to be_enabled
      end
    end

    it "narrates a large tree on a terminal" do
      expect(described_class.for(units: 10_000, io: terminal))
        .to be_enabled
    end

    it "honors --progress on a small tree and a plain stream" do
      expect(described_class.for(units: 1, wanted: true,
        io: StringIO.new)).to be_enabled
    end

    it "honors --no-progress on a large tree" do
      expect(described_class.for(units: 10_000, wanted: false,
        io: terminal)).not_to be_enabled
    end

    it "rewrites a line on a terminal and logs off one" do
      expect(described_class.for(units: 1, wanted: true,
        io: terminal).renderer).to be_a(described_class::Line)
      expect(described_class.for(units: 1, wanted: true,
        io: StringIO.new).renderer).to be_a(described_class::Log)
    end
  end

  describe "the status line" do
    it "rewrites one line and erases it at the end" do
      io = StringIO.new
      progress = line(io)

      progress.phase("checking", total: 4) { |p| p.tick(2) }
      progress.finish

      frames = io.string.split("\r").reject(&:empty?)
      expect(frames.first).to include("Audition checking 0/4 0%")
      expect(io.string).not_to include("\n")
      expect(frames.last.strip).to be_empty
    end

    it "names the stage inside a phase" do
      io = StringIO.new

      line(io).phase("gem calls") do |p|
        p.stage("scanning", total: 10)
        p.tick(5)
      end

      expect(io.string).to include("gem calls scanning 5/10 50%")
    end

    it "says how many Ractors the phase is running on" do
      io = StringIO.new

      line(io).phase("checking", total: 10) do |p|
        p.ractors = 8
        p.tick(5)
      end

      expect(io.string)
        .to match(/checking 5\/10 50% \(\d+\.\ds, on 8 ractors\)/)
    end

    it "claims no Ractors while the work is serial" do
      io = StringIO.new

      progress = line(io)
      progress.phase("checking", total: 2) { |p| p.ractors = 4 }
      progress.phase("graph", total: 2) { |p| p.tick }

      expect(io.string.split("graph").last).not_to include("ractors")
    end

    it "spins when there is nothing to count" do
      io = StringIO.new

      line(io).phase("graph") { |p| p.stage("resolving") }

      expect(io.string).to match(%r{graph resolving [|/\\-] \(\d+\.\ds\)})
    end

    it "clamps a count that overruns its total" do
      io = StringIO.new

      line(io).phase("checking", total: 2) { |p| p.tick(50) }

      expect(io.string).to include(" 100% (")
    end

    it "keeps the visible width inside the terminal" do
      io = StringIO.new
      progress = nil
      with_columns("40") { progress = line(io) }

      progress.phase("a phase with a very long name indeed",
        total: 1_000_000) { |p| p.tick }

      widest = io.string.split("\r").map(&:length).max
      expect(widest).to be <= 39
    end

    it "survives a stream that goes away" do
      io = StringIO.new
      progress = line(io)
      allow(io).to receive(:write).and_raise(IOError)

      expect { progress.phase("checking", total: 1, &:tick) }
        .not_to raise_error
    end

    def with_columns(value)
      previous = ENV["COLUMNS"]
      ENV["COLUMNS"] = value
      yield
    ensure
      ENV["COLUMNS"] = previous
    end
  end

  describe "named units" do
    it "counts and names without restarting the count" do
      io = StringIO.new

      line(io).phase("sweep", total: 2, unit: "gems") do |p|
        p.item("pastel")
        p.item("tty-link")
      end

      expect(io.string).to include("sweep tty-link 2/2 100%")
    end
  end

  describe "the log" do
    it "writes one completion line per phase" do
      io = StringIO.new
      progress = log(io)

      progress.phase("learning", total: 30) { |p| p.tick }
      progress.phase("graph") { |p| p.stage("resolving") }
      progress.finish

      lines = io.string.lines.map(&:chomp)
      expect(lines.first).to match(/\AAudition: learning: 30 files in/)
      expect(lines.last).to match(/\AAudition: graph in \d+\.\ds\z/)
      expect(io.string).not_to include("\r")
    end

    it "reports the Ractor count a phase ran on" do
      io = StringIO.new

      log(io).phase("checking", total: 30) { |p| p.ractors = 8 }

      expect(io.string.lines.last.chomp).to match(
        /\AAudition: checking: 30 files in \d+\.\ds on 8 ractors\z/
      )
    end

    it "writes a line per named unit and counts the unit" do
      io = StringIO.new

      log(io).phase("sweep", total: 2, unit: "gems") do |p|
        p.item("pastel")
      end

      lines = io.string.lines.map(&:chomp)
      expect(lines.first).to eq("Audition: sweep pastel (1/2)")
      expect(lines.last).to match(/\AAudition: sweep: 2 gems in/)
    end
  end

  describe "when silent" do
    it "yields itself and absorbs every call" do
      silent = described_class::SILENT

      expect(silent).not_to be_enabled
      expect(silent.phase("x", total: 2) { |p| p.tick || 7 }).to eq(7)
      expect(silent.count).to eq(0)
      expect { silent.stage("y", total: 1) }.not_to raise_error
      expect { silent.ractors = 4 }.not_to raise_error
      expect(silent.ractors).to be_nil
      expect { silent.finish }.not_to raise_error
    end

    # The default every analysis entry point holds, so a worker
    # can be handed one.
    it "is shareable" do
      expect(Ractor.shareable?(described_class::SILENT)).to be(true)
    end
  end
end
