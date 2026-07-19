# frozen_string_literal: true

require "prism"

module Audition
  module Static
    module Checks
      # A check is a Prism visitor plus a message catalog, written in
      # a small declarative DSL:
      #
      #   class MyCheck < Base
      #     check_name "my-check"           # optional; derived
      #
      #     explain :bad_thing,
      #             severity: :error,
      #             message: "found %{name}",
      #             why: "it breaks because ...",
      #             fix: "do this instead ..."
      #
      #     on :call_node do |node|
      #       flag(node, :bad_thing, name: node.name)
      #     end
      #   end
      #
      # `on` generates the visit method and always continues into
      # child nodes, so handlers cannot accidentally stop traversal.
      # Third-party checks plug in via Checks.register(MyCheck).
      class Base < Prism::Visitor
        EMPTY_CATALOG = {}.freeze

        class << self
          # No lazy memoization here: checks must be readable from
          # non-main Ractors (parallel scanning), so class-level
          # state is written eagerly on the main Ractor at class
          # definition time and kept deeply shareable.
          #
          # @param value [String, nil] sets the identifier when
          #   given; otherwise derived from the class name
          # @return [String] kebab-case check identifier
          def check_name(value = nil)
            @check_name = -value if value # audition:disable class-level-state
            @check_name || (name || "anonymous-check").split("::")
              .last.gsub(/([a-z0-9])([A-Z])/, '\1-\2').downcase
          end

          # Catalogs merge down the ancestry so a subclass of a
          # concrete check inherits its handlers and messages
          # instead of raising KeyError at visit time.
          def explanations
            own = @explanations || EMPTY_CATALOG
            parent = superclass
            if parent.respond_to?(:explanations)
              parent.explanations.merge(own)
            else
              own
            end
          end

          # Registers a message catalog entry. Strings may contain
          # `%{placeholders}` filled by {#flag}.
          #
          # @param key [Symbol] catalog key used by {#flag}
          # @param severity [Symbol] `:error`, `:warning`, `:info`
          # @param message [String] one-line problem statement
          # @param why [String] the Ractor rule behind it
          # @param fix [String] suggested remediation
          # @return [void]
          def explain(key, severity:, message:, why:, fix:)
            entry = {
              severity: severity, message: message,
              why: why, fix: fix
            }
            @explanations = Ractor.make_shareable( # audition:disable
              explanations.merge(key => entry)
            )
          end

          def handlers
            own = @handlers || EMPTY_CATALOG
            parent = superclass
            if parent.respond_to?(:handlers)
              parent.handlers.merge(own)
            else
              own
            end
          end

          # Methods born from define_method carry their block as a
          # Proc, and Ruby refuses to call them from another Ractor
          # unless that Proc is shareable. Both the handler and the
          # generated wrapper are therefore isolated via
          # Ractor.make_shareable; the wrapper looks its handler up
          # through __method__ and continues traversal explicitly
          # (super is not available inside an isolated proc, and
          # this reproduces Prism::Visitor's default body).
          WRAPPER = Ractor.make_shareable(
            proc do |node|
              handler_for(__method__, node)
              node.each_child_node { |child| child.accept(self) }
            end
          )

          # Generates visit methods for the given Prism node types.
          # The handler runs via instance_exec and traversal always
          # continues into child nodes afterwards. Handlers must not
          # capture outer locals (they are isolated for cross-Ractor
          # use and Ractor.make_shareable would raise).
          #
          # @param node_types [Array<Symbol>] e.g. `:call_node`
          # @yieldparam node [Prism::Node] the visited node
          # @return [void]
          def on(*node_types, &handler)
            isolated = Ractor.make_shareable(handler)
            node_types.each do |type|
              method_name = :"visit_#{type}"
              @handlers = Ractor.make_shareable( # audition:disable
                handlers.merge(method_name => isolated)
              )
              define_method(method_name, &WRAPPER)
            end
          end

          # Runs this check over one parsed file.
          #
          # @param file [SourceFile]
          # @return [Array<Finding>]
          def call(file)
            visitor = new(file)
            visitor.visit(file.root)
            visitor.findings
          end
        end

        attr_reader :file, :findings

        def initialize(file)
          @file = file
          @findings = []
          super()
        end

        private

        def handler_for(method_name, node)
          instance_exec(node, &self.class.handlers.fetch(method_name))
        end

        def flag(node, key, autofix: nil, **interp)
          spec = self.class.explanations.fetch(key)
          add(node,
            severity: spec[:severity],
            message: format(spec[:message], **interp),
            why: format(spec[:why], **interp),
            fix: format(spec[:fix], **interp),
            autofix: autofix)
        end

        def add(node, severity:, message:, why:, fix:, autofix: nil)
          line = node.location.start_line
          @findings << Finding.new(
            check: self.class.check_name,
            severity: severity,
            message: message,
            why: why,
            fix: fix,
            path: file.path,
            line: line,
            source: file.line_at(line),
            autofix: autofix
          )
        end
      end
    end
  end
end
