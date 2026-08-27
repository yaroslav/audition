# frozen_string_literal: true

require "pastel"
require "tty/link"

module Audition
  class Report
    # ANSI + OSC 8 styling with graceful degradation. Color and
    # hyperlinks are decided once, at construction; pass color: false
    # for pipes, NO_COLOR, or dumb terminals.
    class Style
      GLYPHS = Ractor.make_shareable(
        {
          error: ["✖", "x"], warning: ["⚠", "!"],
          info: ["ℹ", "i"], pass: ["✔", "ok"],
          section: ["◆", "*"], fix: ["✎", "+"]
        }
      )

      PAINTS = %i[red yellow green cyan magenta dim bold].freeze

      def self.detect(io: $stdout)
        on = io.respond_to?(:tty?) && io.tty? &&
          !ENV.key?("NO_COLOR") && ENV["TERM"] != "dumb"
        new(color: on, hyperlinks: on && TTY::Link.link?)
      end

      def initialize(color:, hyperlinks:)
        @pastel = Pastel.new(enabled: color)
        @color = color
        @hyperlinks = hyperlinks
      end

      def color?
        @color
      end

      def glyph(kind)
        GLYPHS.fetch(kind)[@color ? 0 : 1]
      end

      PAINTS.each do |name|
        define_method(name) do |text| # audition:disable unsafe-calls
          @pastel.public_send(name, text)
        end
      end

      def severity_color(severity, text)
        case severity
        when :error then red(text)
        when :warning then yellow(text)
        else cyan(text)
        end
      end

      # OSC 8 hyperlink wrapping "path:line" display text in a
      # file:// URI; supporting terminals make it clickable.
      # tty-link emits when it detects support; when hyperlinks are
      # forced on despite no detection (tests, --force scenarios)
      # fall back to the raw OSC 8 template, since tty-link's
      # fallback is "text -> url" prose.
      def link(text, absolute_path)
        return text unless @hyperlinks

        uri = "file://#{absolute_path}"
        if TTY::Link.link?
          TTY::Link.link_to(text, uri)
        else
          "\e]8;;#{uri}\e\\#{text}\e]8;;\e\\"
        end
      end
    end
  end
end
