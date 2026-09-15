# frozen_string_literal: true

require "etc"

module Audition
  module Static
    # How a scan is divided between Ractor workers.
    module WorkSplit
      # Ractors run on a fixed pool of native threads sized by
      # RUBY_MAX_CPU, which only the environment can set. Spawning
      # past it buys no parallelism and costs a Ractor each.
      RACTOR_CPU_DEFAULT = 8

      module_function

      # One worker per core the Ractor pool can actually run. The
      # main Ractor only waits while workers scan, so no core is
      # held back for it.
      #
      # @return [Integer]
      def workers
        Etc.nprocessors.clamp(1, ractor_cpu_limit)
      end

      def ractor_cpu_limit
        limit = ENV["RUBY_MAX_CPU"].to_i
        limit.positive? ? limit : RACTOR_CPU_DEFAULT
      end

      # Longest-processing-time-first: deal the heaviest item onto
      # the lightest worker. Consecutive files are neighbors in the
      # tree and so alike in size, so contiguous slices come out
      # lopsided: one worker can draw a slice weighing several times
      # the mean and still be running once the rest have finished.
      # Greedy is enough here: LPT finishes within 4/3 of an
      # optimal split.
      #
      # @param weighted [Array<Array>] `[item, weight]` pairs
      # @param count [Integer] worker count
      # @return [Array<Array>] one chunk of items per busy worker
      def chunks(weighted, count)
        chunks = Array.new(count) { [] }
        loads = Array.new(count, 0)
        weighted.sort_by { |item, weight| [-weight, item] }
          .each do |item, weight|
            lightest = loads.index(loads.min)
            chunks[lightest] << item
            loads[lightest] += weight
          end
        chunks.reject(&:empty?)
      end
    end
  end
end
