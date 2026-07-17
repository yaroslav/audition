# frozen_string_literal: true

module Audition
  module Static
    module Checks
      # `require` inside a non-main Ractor works on Ruby 4.0 by
      # proxying the call to the main Ractor; but that serializes
      # every Ractor through a single lock, and it means load-time
      # side effects run mid-request. `autoload` is the same hazard
      # in disguise: the require fires whenever the constant happens
      # to be resolved first, possibly inside a Ractor.
      class RuntimeRequire < Base
        REQUIRE_METHODS = %i[require require_relative load].freeze

        explain :runtime_require,
          severity: :warning,
          message: "%{method} at runtime (inside a method " \
                   "body)",
          why: "On Ruby 4.0, require inside a non-main " \
               "Ractor is proxied to the main Ractor: it " \
               "works, but all Ractors serialize on it and " \
               "load-time side effects run at an arbitrary " \
               "point.",
          fix: "Require eagerly at boot, before Ractors are " \
               "spawned."

        explain :autoload,
          severity: :warning,
          message: "autoload registers a deferred require",
          why: "The require fires when the constant is first " \
               "resolved, which may happen inside a non-main " \
               "Ractor, serializing Ractors through the " \
               "main-Ractor require proxy.",
          fix: "Require eagerly at boot, or resolve the " \
               "constant once on the main Ractor before " \
               "spawning."

        on :call_node do |node|
          if node.receiver.nil?
            if REQUIRE_METHODS.include?(node.name) && inside_def?
              unless hoisted_already?(node)
                flag(node, :runtime_require, method: node.name,
                  autofix: hoist_autofix(node))
              end
            elsif node.name == :autoload
              flag(node, :autoload,
                autofix: require_conversion_autofix(node))
            end
          end
        end

        def visit_def_node(node)
          @def_depth = def_depth + 1
          super
        ensure
          @def_depth -= 1
        end

        private

        def def_depth = @def_depth ||= 0

        def inside_def? = def_depth.positive?

        def literal_feature(node)
          return nil unless node.name == :require ||
            node.name == :require_relative

          arg = node.arguments&.arguments&.first
          arg if arg.is_a?(Prism::StringNode) &&
            node.arguments.arguments.size == 1
        end

        # A method-body require whose feature is already required at
        # the top of the same file is a fast no-op; not worth a
        # finding.
        def hoisted_already?(node)
          feature = literal_feature(node)
          !feature.nil? &&
            file.top_level_requires.include?(feature.unescaped)
        end

        # Requiring is idempotent, so inserting a boot-time
        # duplicate preserves semantics exactly while removing the
        # runtime serialization. `load` is excluded: it re-executes
        # on every call.
        def hoist_autofix(node)
          feature = literal_feature(node)
          return nil unless feature

          insertion = file.boot_insertion
          offset = insertion[:offset]
          statement = "#{node.name} #{feature.location.slice}"
          if insertion[:after_require]
            Autofix.new(start_offset: offset, end_offset: offset,
              replacement: "#{statement}\n")
          else
            offset += 1 if newline_at?(offset)
            Autofix.new(start_offset: offset, end_offset: offset,
              replacement: "#{statement}\n\n")
          end
        end

        def newline_at?(offset)
          file.source.byteslice(offset, 1) == "\n"
        end

        # Eager require is exactly the trade a Ractor deployment
        # wants, but it changes load timing: unsafe tier.
        def require_conversion_autofix(node)
          args = node.arguments&.arguments
          return nil unless args&.size == 2 &&
            args[0].is_a?(Prism::SymbolNode) &&
            args[1].is_a?(Prism::StringNode)

          Autofix.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement: "require #{args[1].location.slice}",
            safety: :unsafe
          )
        end
      end
    end
  end
end
