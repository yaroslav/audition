# frozen_string_literal: true

module Audition
  module Static
    module Checks
      # Knowledge base of APIs that are hostile (or noteworthy)
      # under Ractors, expressed as catalog entries plus call-site
      # matching rules. Severities reflect behavior verified on
      # Ruby 4.0; several 3.x-era errors (ENV, trap,
      # ObjectSpace.each_object) now work and are only
      # informational.
      class UnsafeCalls < Base
        explain :ractor_yield_removed,
          severity: :error,
          message: "Ractor.%{method} was removed in Ruby 4.0",
          why: "The yield/take rendezvous API was replaced " \
               "by Ractor::Port in Ruby 4.0; calling it " \
               "raises NoMethodError.",
          fix: "Create a Ractor::Port, pass it into the " \
               "Ractor, and use port.send/port.receive; " \
               "collect results with Ractor#value."

        explain :rails_class_state_macro,
          severity: :error,
          message: "%{method} stores state on the class " \
                   "object",
          why: "These ActiveSupport macros are backed by " \
               "class-level instance variables or class " \
               "variables; both raise Ractor::IsolationError " \
               "when written (and class variables even when " \
               "read) from a non-main Ractor.",
          fix: "Compute the value at boot and store it in a " \
               "deeply frozen constant, or keep per-Ractor " \
               "state via Ractor.current[:key] / " \
               "Ractor.store_if_absent."

        explain :objectspace_id2ref,
          severity: :warning,
          message: "ObjectSpace._id2ref cannot resolve " \
                   "objects across Ractors",
          why: "Object IDs are only meaningful within the " \
               "Ractor that created the object; _id2ref is " \
               "also deprecated since Ruby 3.4.",
          fix: "Pass objects (or their data) through " \
               "Ractor::Port messages instead of smuggling " \
               "object IDs."

        explain :at_exit,
          severity: :info,
          message: "at_exit registers a process-global hook",
          why: "Hooks run on the main Ractor at process " \
               "exit; registering them from short-lived " \
               "Ractors accumulates process-global state.",
          fix: "Register exit hooks once, from the main " \
               "Ractor, at boot."

        explain :signal_trap,
          severity: :info,
          message: "%{receiver}trap installs a process-global " \
                   "signal handler",
          why: "Works on Ruby 4.0 even from a Ractor, but " \
               "the handler is process-wide; Ractors " \
               "installing competing handlers race.",
          fix: "Install signal handlers once, on the main " \
               "Ractor."

        explain :env_write,
          severity: :info,
          message: "ENV mutation is process-global",
          why: "Works on Ruby 4.0 (ENV access from Ractors " \
               "no longer raises), but the environment is " \
               "shared mutable state; concurrent Ractors " \
               "race on it.",
          fix: "Read configuration into frozen constants at " \
               "boot instead of mutating ENV at runtime."

        explain :fork,
          severity: :warning,
          message: "%{method} from a multi-Ractor process",
          why: "fork only reproduces the calling thread; " \
               "other Ractors' threads vanish in the child, " \
               "leaving their state inconsistent.",
          fix: "Fork before spawning Ractors, or use " \
               "spawn/exec."

        explain :singleton_include,
          severity: :warning,
          message: "include Singleton memoizes the instance " \
                   "on the class",
          why: "Singleton stores its instance in a " \
               "class-level instance variable; the first " \
               "access from a non-main Ractor raises " \
               "Ractor::IsolationError when it tries to " \
               "write it.",
          fix: "Eagerly call .instance on the main Ractor " \
               "at boot (freezing the instance if possible), " \
               "or use Ractor.store_if_absent."

        RULES = Ractor.make_shareable([
          {key: :ractor_yield_removed, receiver: "Ractor",
           methods: %i[yield take]},
          {key: :rails_class_state_macro, receiver: nil,
           methods: %i[class_attribute cattr_accessor cattr_reader
             cattr_writer mattr_accessor mattr_reader
             mattr_writer thread_mattr_accessor]},
          {key: :objectspace_id2ref, receiver: "ObjectSpace",
           methods: %i[_id2ref]},
          {key: :at_exit, receiver: nil, methods: %i[at_exit]},
          {key: :signal_trap, receiver: "Signal",
           methods: %i[trap]},
          {key: :signal_trap, receiver: nil, methods: %i[trap]},
          {key: :env_write, receiver: "ENV",
           methods: %i[[]= store delete update clear replace]},
          {key: :fork, receiver: nil, methods: %i[fork]},
          {key: :fork, receiver: "Process",
           methods: %i[fork daemon]}
        ])

        on :call_node do |node|
          apply_rules(node)
          flag_singleton_include(node)
        end

        private

        def apply_rules(node)
          rule = RULES.find do |r|
            r[:methods].include?(node.name) &&
              receiver_matches?(r[:receiver], node.receiver)
          end
          return unless rule

          receiver = rule[:receiver] ? "#{rule[:receiver]}." : ""
          flag(node, rule[:key],
            method: "#{receiver}#{node.name}",
            receiver: receiver)
        end

        def receiver_matches?(expected, receiver)
          return receiver.nil? if expected.nil?

          case receiver
          when Prism::ConstantReadNode
            receiver.name.to_s == expected
          when Prism::ConstantPathNode
            receiver.location.slice == expected
          else
            false
          end
        end

        def flag_singleton_include(node)
          return unless node.name == :include && node.receiver.nil?

          args = node.arguments&.arguments or return
          singleton = args.any? do |a|
            a.is_a?(Prism::ConstantReadNode) && a.name == :Singleton
          end
          return unless singleton

          flag(node, :singleton_include)
        end
      end
    end
  end
end
