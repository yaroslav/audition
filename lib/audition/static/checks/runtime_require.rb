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
                autofix = rescued? ? nil : hoist_autofix(node)
                flag(node, :runtime_require, method: node.name,
                  autofix: autofix)
              end
            elsif node.name == :autoload
              unless eagerly_loaded?(node)
                flag(node, :autoload,
                  autofix: require_conversion_autofix(node))
              end
            end
          end
        end

        def visit_def_node(node)
          @def_depth = def_depth + 1
          super
        ensure
          @def_depth -= 1
        end

        # A require under a rescue is conditional by construction
        # (optional dependencies, tzinfo's tzinfo-data); hoisting
        # it to an unguarded top-level require breaks every
        # installation without the feature.
        def visit_begin_node(node)
          if node.rescue_clause
            @rescue_depth = rescue_depth + 1
            begin
              super
            ensure
              @rescue_depth -= 1
            end
          else
            super
          end
        end

        def visit_rescue_modifier_node(node)
          @rescue_depth = rescue_depth + 1
          super
        ensure
          @rescue_depth -= 1
        end

        private

        def def_depth = @def_depth ||= 0

        def inside_def? = def_depth.positive?

        def rescue_depth = @rescue_depth ||= 0

        def rescued? = rescue_depth.positive?

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

        # Requiring is idempotent, so a boot-time duplicate leaves
        # the method's behavior alone; but it does load the feature
        # in every context, and files can be deliberately lazy
        # (optional dependencies, i18n's test-DSL mixins), so this
        # is unsafe tier. `load` is excluded: it re-executes on
        # every call.
        def hoist_autofix(node)
          feature = literal_feature(node)
          return nil unless feature

          insertion = file.boot_insertion
          offset = insertion[:offset]
          statement = "#{node.name} #{feature.location.slice}"
          if insertion[:after_require]
            Autofix.new(start_offset: offset, end_offset: offset,
              replacement: "#{statement}\n", safety: :unsafe)
          else
            offset += 1 if newline_at?(offset)
            Autofix.new(start_offset: offset, end_offset: offset,
              replacement: "#{statement}\n\n", safety: :unsafe)
          end
        end

        def newline_at?(offset)
          file.source.byteslice(offset, 1) == "\n"
        end

        # The eager conversion is only offered when the autoloaded
        # feature resolves to a file inside the target itself and
        # that file carries no optional-dependency guard: a
        # `rescue LoadError` means the file is deliberately lazy
        # (i18n's key_value backend), and a feature that does not
        # resolve locally may not even be installed.
        def convertible_feature?(feature)
          candidate = resolve_locally(feature)
          !candidate.nil? &&
            !File.read(candidate).include?("rescue LoadError")
        rescue SystemCallError
          false
        end

        def resolve_locally(feature)
          roots = [File.dirname(file.path)]
          if (index = file.path.rindex("/lib/"))
            roots << file.path[0, index + 4]
          end
          roots.filter_map { |root|
            candidate = File.join(root, "#{feature}.rb")
            candidate if File.file?(candidate)
          }.first
        end

        def autoload_feature(node)
          args = node.arguments&.arguments
          return nil unless args&.size == 2 &&
            args[0].is_a?(Prism::SymbolNode) &&
            args[1].is_a?(Prism::StringNode)

          args[1]
        end

        # An autoload whose feature is also required at the top
        # level of the same file is eagerly loaded; the remaining
        # registration is a harmless safety net.
        def eagerly_loaded?(node)
          feature = autoload_feature(node)
          !feature.nil? &&
            file.top_level_requires.include?(feature.unescaped)
        end

        # Eager require is exactly the trade a Ractor deployment
        # wants, but it changes load timing: unsafe tier. The
        # autoload line stays and the require lands at the end of
        # the file, after every registration in it: requiring in
        # registration order breaks mutual references (file A
        # loads first, references B, whose registration was
        # converted away), while a kept registration resolves any
        # constant the eager load path touches.
        def require_conversion_autofix(node)
          feature = autoload_feature(node)
          return nil unless feature
          return nil unless convertible_feature?(feature.unescaped)

          eof = file.source.bytesize
          statement = "require #{feature.location.slice}\n"
          Autofix.new(
            start_offset: eof,
            end_offset: eof,
            replacement: statement,
            safety: :unsafe
          )
        end
      end
    end
  end
end
