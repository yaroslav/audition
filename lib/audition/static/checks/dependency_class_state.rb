# frozen_string_literal: true

module Audition
  module Static
    module Checks
      # Class-level state owned by a dependency. A gem's own source
      # is outside the scanned tree, so the graph audit never sees
      # the ivar and the call site is the only place left to flag.
      # Generated type stubs in the target's tree record it: an
      # attribute reader on a singleton class is a class-level ivar
      # read by definition, and the generator marks those methods
      # apart from ones that compute their answer.
      class DependencyClassState < Base
        explain :read,
          severity: :warning,
          message: "%{owner}.%{name} reads class-level state " \
                   "owned by a dependency",
          why: "The stub for %{owner} declares %{name} as an " \
               "attribute on its singleton class, so the call " \
               "returns a class-level instance variable. A " \
               "non-main Ractor raises Ractor::IsolationError " \
               "(\"can not get unshareable values from instance " \
               "variables of classes/modules\") unless whatever " \
               "the value happens to be is shareable.",
          fix: "Read it once on the main Ractor and pass the " \
               "value in, or make the dependency's assignment " \
               "deeply shareable before any Ractor starts."

        explain :write,
          severity: :error,
          message: "%{owner}.%{name}= writes class-level state " \
                   "owned by a dependency",
          why: "Assigning an attribute on %{owner}'s singleton " \
               "class writes a class-level instance variable, " \
               "which a non-main Ractor cannot do at all: it " \
               "raises Ractor::IsolationError regardless of what " \
               "the value is.",
          fix: "Configure the dependency at boot on the main " \
               "Ractor and leave it alone afterwards."

        # The generator documents a reader it generated from an
        # attribute; a hand-written method of the same shape gets
        # its own prose and stays quiet.
        STUB_READER = /Returns the value of attribute (\w+)/
        STUB_SINGLETON = /\A\s*class\s+<<\s+self\b/
        STUB_SCOPE = /\A\s*(?:class|module)\s+([A-Za-z0-9_:]+)/
        STUB_DEF = /\A\s*def ([a-z_][A-Za-z0-9_]*)[(;]/
        STUB_COMMENT = /\A\s*#/

        class << self
          attr_reader :attributes

          # Owner name => set of attribute names, kept shareable
          # for parallel scanning.
          def attributes=(pairs)
            grouped = pairs.group_by(&:first)
              .transform_values { |v| v.map(&:last).uniq }
            @attributes = Ractor.make_shareable( # audition:disable
              grouped
            )
          end

          # @param paths [Array<String>] scanned files; only
          #   generated type stubs carry this evidence
          # @return [void]
          def learn(paths)
            pairs = []
            paths.each do |path|
              next unless path.end_with?(".rbi")

              read_stub(path, pairs)
            end
            self.attributes = pairs
          end

          private

          # Stub indentation tracks nesting exactly, so the scope
          # stack follows it rather than parsing the file.
          def read_stub(path, pairs)
            scope = []
            singleton = []
            indents = []
            documented = nil
            File.foreach(path) do |raw|
              line = raw.rstrip
              next if line.empty?

              indent = line[/\A */].size
              while indents.any? && indent <= indents.last
                indents.pop
                scope.pop
                singleton.pop
              end
              documented =
                step_stub(line, scope, singleton, indents,
                  documented, pairs)
            end
          rescue SystemCallError
            nil
          end

          def step_stub(line, scope, singleton, indents,
            documented, pairs)
            case line
            when STUB_COMMENT
              return STUB_READER.match(line)&.[](1) || documented
            when STUB_SINGLETON
              scope.push(scope.last)
              singleton.push(true)
              indents.push(line[/\A */].size)
            when STUB_SCOPE
              name = Regexp.last_match(1)
              scope.push(scope.empty? ? name : "#{scope.last}::#{name}")
              singleton.push(false)
              indents.push(line[/\A */].size)
            when STUB_DEF
              name = Regexp.last_match(1)
              if singleton.last && scope.last && documented == name
                pairs << [scope.last, name]
              end
            end
            nil
          end
        end

        self.attributes = []

        on :call_node do |node|
          examine(node)
        end

        private

        def examine(node)
          owner = constant_name(node.receiver)
          return unless owner

          name = node.name.to_s
          writer = name.end_with?("=")
          attribute = writer ? name.chomp("=") : name
          names = self.class.attributes[owner]
          return unless names&.include?(attribute)

          flag(node, writer ? :write : :read,
            owner: owner, name: attribute)
        end

        def constant_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            node.location.slice.delete_prefix("::")
          end
        end
      end
    end
  end
end
