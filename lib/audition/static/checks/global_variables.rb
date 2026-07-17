# frozen_string_literal: true

module Audition
  module Static
    module Checks
      # Non-main Ractors cannot touch global variables: reads and
      # writes raise Ractor::IsolationError. The exceptions below are
      # ractor-local or frame-local and verified safe on Ruby 4.0.
      # Regexp capture globals ($1, $&, $`, $', $+) are separate
      # Prism node types and never flagged.
      class GlobalVariables < Base
        SAFE_READS = %w[
          $stdin $stdout $stderr $! $? $~ $_ $DEBUG $VERBOSE $/ $$
        ].freeze
        SAFE_WRITES = %w[$DEBUG $VERBOSE].freeze
        LOAD_PATH_GLOBALS = %w[$LOAD_PATH $: $LOADED_FEATURES $"].freeze

        explain :access,
          severity: :error,
          message: "%{access} global variable %{name}",
          why: "Non-main Ractors cannot access global " \
               "variables; this raises Ractor::IsolationError " \
               "the moment the line executes in a Ractor " \
               "(verified on Ruby 4.0).",
          fix: "Pass the value into the Ractor explicitly " \
               "(Ractor.new(value) { |v| ... }) or over a " \
               "Ractor::Port; for per-Ractor state use " \
               "Ractor.current[:key]; do one-time process " \
               "setup on the main Ractor before spawning."

        explain :load_path,
          severity: :error,
          message: "%{access} global variable %{name}",
          why: "The load path ($LOAD_PATH/$LOADED_FEATURES) " \
               "is main-Ractor-only global state; touching " \
               "it from a non-main Ractor raises " \
               "Ractor::IsolationError.",
          fix: "Adjust the load path on the main Ractor " \
               "during boot, before any Ractors are spawned."

        on :global_variable_read_node do |node|
          unless SAFE_READS.include?(node.name.to_s)
            gvar(node, "read of")
          end
        end

        on :global_variable_write_node,
          :global_variable_operator_write_node,
          :global_variable_or_write_node,
          :global_variable_and_write_node,
          :global_variable_target_node do |node|
          unless SAFE_WRITES.include?(node.name.to_s)
            gvar(node, "write to")
          end
        end

        private

        def gvar(node, access)
          name = node.name.to_s
          key = LOAD_PATH_GLOBALS.include?(name) ? :load_path : :access
          flag(node, key, access: access, name: name)
        end
      end
    end
  end
end
