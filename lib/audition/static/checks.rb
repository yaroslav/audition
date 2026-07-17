# frozen_string_literal: true

require_relative "checks/base"
require_relative "checks/global_variables"
require_relative "checks/mutable_constants"
require_relative "checks/ractor_isolation"
require_relative "checks/runtime_require"
require_relative "checks/unsafe_calls"

module Audition
  module Static
    module Checks
      BUILT_IN = [
        GlobalVariables, MutableConstants, RactorIsolation,
        RuntimeRequire, UnsafeCalls
      ].freeze

      # Expression-level checks, run per file. Class variables and
      # class-level instance variable state are covered semantically
      # by the rubydex graph audit, not by per-file visitors.
      #
      # @return [Array<Class>] built-in plus registered checks
      def self.all
        BUILT_IN + registered
      end

      # Extension point: gems can subclass {Base} and register here.
      #
      # @param check [Class] a {Base} subclass
      # @return [void]
      def self.register(check)
        registered << check
      end

      # @param check [Class] a previously registered check
      # @return [void]
      def self.deregister(check)
        registered.delete(check)
      end

      def self.registered
        @registered ||= [] # audition:disable class-level-state
      end
    end
  end
end
