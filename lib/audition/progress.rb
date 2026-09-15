# frozen_string_literal: true

module Audition
  # Narrates a scan phase by phase on stderr. This class tracks
  # only where the scan has got to; what the narration looks
  # like—a line rewritten in place, a line per phase, or nothing
  # at all—belongs to the renderer.
  class Progress
    # Below this many files a scan ends before a reader could read
    # the first redraw.
    AUTO_THRESHOLD = 200

    # Shared by the renderers: both write to a stream that may go
    # away, both spell out counts and durations the same way, and
    # both paint with the palette the report uses.
    class Renderer
      def self.terminal?(io)
        io.respond_to?(:tty?) && io.tty?
      rescue IOError
        false
      end

      # @param io [IO]
      # @param style [Report::Style] defaults to whatever the
      #   stream supports, so a redirected run comes out plain
      def initialize(io, style: nil)
        @io = io
        @style = style || Report::Style.detect(io: io)
        @live = true
      end

      def update(progress) = nil

      # A named unit is still just progress unless the renderer
      # has a reason to treat it differently.
      def item(progress) = update(progress)

      def phase_done(progress) = nil

      def clear = nil

      private

      def fraction(progress)
        count = commas(progress.count)
        total = progress.total
        total ? "#{count}/#{commas(total)}" : count
      end

      # Narration is cosmetic: a stream that has gone away ends it,
      # never the scan.
      def write(text)
        return unless @live

        @io.write(text)
        @io.flush if @io.respond_to?(:flush)
      rescue IOError, SystemCallError
        @live = false
      end

      def seconds(value)
        format("%.1fs", value)
      end

      def commas(value)
        value.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
      end

      # Named rather than dynamic dispatch, so the check for unsafe
      # sends needs no exception here.
      def paint(text, color)
        case color
        when :bold then @style.bold(text)
        when :dim then @style.dim(text)
        when :cyan then @style.cyan(text)
        when :green then @style.green(text)
        when :magenta then @style.magenta(text)
        else text
        end
      end
    end

    # One status line, rewritten in place for the whole scan and
    # erased when it ends.
    class Line < Renderer
      # Redraws closer together than this are invisible and cost a
      # syscall on every file.
      REDRAW_INTERVAL = 0.1

      # Stands in for the counter while a stage runs work that
      # cannot be counted, so the line still moves.
      SPINNER = %w[| / - \\].freeze

      DEFAULT_WIDTH = 80
      MIN_WIDTH = 24

      def self.width
        columns = ENV["COLUMNS"].to_i
        (columns >= MIN_WIDTH) ? columns : DEFAULT_WIDTH
      end

      # @param interval [Float] seconds between redraws within one
      #   stage; zero draws every update
      def initialize(io, style: nil, interval: REDRAW_INTERVAL)
        super(io, style: style)
        @interval = interval
        @width = self.class.width
        @drawn = 0
        @heading = nil
        @redrawn_at = 0.0
        @spin = 0
        @mutex = Mutex.new
        @heartbeat = nil
      end

      def update(progress)
        if progress.countable?
          stop_heartbeat
        else
          start_heartbeat(progress)
        end
        draw(progress)
      end

      def clear
        stop_heartbeat
        @mutex.synchronize { erase }
      end

      private

      # Work with nothing to count would leave the line frozen,
      # which reads as a hang, so a thread keeps the clock and the
      # spinner moving until something countable starts.
      def start_heartbeat(progress)
        return if @heartbeat

        @heartbeat = Thread.new do
          loop do
            sleep(REDRAW_INTERVAL)
            @spin += 1
            draw(progress)
          end
        end
        nil
      end

      # `Mutex#synchronize` releases through `ensure`, so killing a
      # drawing thread cannot leave the lock held.
      def stop_heartbeat
        @heartbeat&.kill
        @heartbeat = nil
      end

      # A new phase or stage is drawn at once; redraws within one
      # are throttled. The scan clock doubles as the throttle
      # clock, so nothing here keeps time of its own.
      def draw(progress)
        @mutex.synchronize do
          heading = heading(progress)
          now = progress.elapsed
          fresh = heading != @heading
          next if !fresh && now - @redrawn_at < @interval

          @heading = heading
          @redrawn_at = now
          render(status(progress, now))
        end
      end

      def heading(progress)
        [progress.label, progress.stage_label].compact.join(" ")
      end

      # The phase carries the weight, the stage and the clock are
      # secondary, and the one moving number gets the accent color.
      def status(progress, now)
        [
          [@style.glyph(:section), :dim],
          ["Audition", :bold],
          [progress.label, :bold],
          [progress.stage_label, :dim],
          *measure(progress),
          [aside(progress, now), :dim]
        ].reject { |text, _| text.nil? || text.empty? }
      end

      def measure(progress)
        return [[spinner, :magenta]] unless progress.countable?

        cells = [[fraction(progress), :cyan]]
        percent = progress.percent
        cells << ["#{percent}%", :green] if percent
        cells
      end

      # How the run is going rather than what it is scanning, kept
      # apart from the counts so neither reads as the other.
      def aside(progress, now)
        count = progress.ractors
        on = count ? ", on #{count} ractors" : ""
        "(#{seconds(now)}#{on})"
      end

      def spinner
        SPINNER[@spin % SPINNER.size]
      end

      # Escape sequences make a painted string's own length useless,
      # so the plain text is what gets measured: padded to the
      # previous width so a shorter status leaves no tail behind,
      # and one column short of the edge so the cursor never wraps.
      # A line too long to fit is trimmed unpainted, since a cut
      # through an escape sequence would corrupt the terminal.
      def render(cells)
        plain = cells.map(&:first).join(" ")
        if plain.length > @width - 1
          plain = plain[0, @width - 1]
          text = plain
        else
          text = cells.map { |cell| paint(*cell) }.join(" ")
        end
        write("\r#{text}#{" " * [@drawn - plain.length, 0].max}\r")
        @drawn = plain.length
      end

      def erase
        return unless @drawn.positive?

        write("\r#{" " * @drawn}\r")
        @drawn = 0
      end
    end

    # One completion line per phase. A log is the only trace a
    # non-interactive run leaves, and a rewritten line would fill
    # it with control characters.
    class Log < Renderer
      # A unit worth naming is worth a line of its own, since
      # nothing here rewrites what came before.
      def item(progress)
        write(
          "#{paint("Audition", :bold)}: #{progress.label} " \
          "#{paint(progress.stage_label.to_s, :bold)} " \
          "#{paint("(#{fraction(progress)})", :dim)}\n"
        )
      end

      # Phases that walk the tree more than once report a duration
      # and no count: each of their stage counts is a fraction of
      # the work.
      def phase_done(progress)
        total = progress.phase_total
        scanned = total ? ": #{commas(total)} #{progress.unit}" : ""
        count = progress.ractors
        on = count ? " on #{count} ractors" : ""
        write(
          "#{paint("Audition", :bold)}: " \
          "#{paint(progress.label, :bold)}#{scanned} in " \
          "#{paint(seconds(progress.phase_elapsed), :dim)}#{on}\n"
        )
      end
    end

    class << self
      # The one clock in play: the renderers throttle and animate
      # against the scan's own elapsed time rather than keeping
      # time of their own.
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # @param units [Integer, nil] work items ahead; nil for work
      #   slow enough to narrate whatever its size, such as a
      #   sweep, where every unit is a scan of its own
      # @param wanted [Boolean, nil] --progress or --no-progress;
      #   nil defers to the unit count, the format and the stream
      # @param format [Symbol] machine formats are never narrated
      # @param io [IO] never the stream carrying the report
      # @param style [Report::Style, nil] nil detects from the
      #   stream; --plain passes a plain one
      # @return [Progress]
      def for(units: nil, wanted: nil, format: :text, io: $stderr,
        style: nil)
        renderer = renderer_for(units, wanted, format, io, style)
        renderer ? new(renderer: renderer) : SILENT
      end

      private

      def renderer_for(units, wanted, format, io, style)
        return nil if wanted == false

        terminal = Renderer.terminal?(io)
        auto = terminal && format == :text &&
          (units.nil? || units >= AUTO_THRESHOLD)
        return nil unless wanted || auto

        klass = terminal ? Line : Log
        klass.new(io, style: style)
      end
    end

    attr_reader :label, :stage_label, :count, :total, :renderer

    # What the phase as a whole covers; its stages divide that up.
    attr_reader :phase_total, :unit

    # How many Ractors the phase is running on, nil while it is
    # serial.
    attr_reader :ractors

    # @param renderer [Renderer, nil] nil narrates nothing
    def initialize(renderer:)
      @renderer = renderer
      @count = 0
      @started = self.class.now
      @phase_started = @started
    end

    # Handed to analysis entry points as their default, so none of
    # them has to ask whether narration is wanted. Shareable, so a
    # worker can hold it, and the guards below keep it that way.
    SILENT = Ractor.make_shareable(new(renderer: nil))

    def enabled?
      !@renderer.nil?
    end

    # Narrates one named phase for the duration of the block.
    #
    # @param label [String] phase name shown to the reader
    # @param total [Integer, nil] units expected, nil when unknown
    # @param unit [String] what the total counts
    def phase(label, total: nil, unit: "files")
      return yield self unless @renderer

      @label = label
      @phase_total = total
      @unit = unit
      @phase_started = self.class.now
      @ractors = nil
      restart(nil, total)
      yield self
    ensure
      @renderer&.phase_done(self)
    end

    # Set by whoever spawns the workers, so the narration can say
    # how much of the machine is at work. The guard keeps {SILENT}
    # frozen and so shareable.
    #
    # @param count [Integer, nil] nil for serial work
    def ractors=(count)
      @ractors = count if @renderer
    end

    # Renames the work within the current phase and restarts its
    # count. A nil total marks a step whose length is not known
    # until it ends, which the renderer is then free to animate.
    def stage(label, total: nil)
      restart(label, total) if @renderer
    end

    def tick(count = 1)
      return unless @renderer

      @count += count
      @renderer.update(self)
    end

    # Counts one unit and names it, for phases whose units are few
    # enough to name. The name takes the stage slot, so nothing in
    # the renderers has to make room for it.
    def item(label)
      return unless @renderer

      @stage_label = label
      @count += 1
      @renderer.item(self)
    end

    # Clears whatever the narration left behind.
    def finish
      @renderer&.clear
    end

    # Seconds since the scan began.
    def elapsed
      self.class.now - @started
    end

    # Seconds since the current phase began.
    def phase_elapsed
      self.class.now - @phase_started
    end

    # @return [Integer, nil] 0..100, nil when nothing bounds it
    def percent
      return nil unless @total&.positive?

      (100 * @count / @total).clamp(0, 100)
    end

    def countable?
      !@total.nil? || @count.positive?
    end

    private

    def restart(stage_label, total)
      @stage_label = stage_label
      @total = total
      @count = 0
      @renderer.update(self)
    end
  end
end
