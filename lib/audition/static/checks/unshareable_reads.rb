# frozen_string_literal: true

module Audition
  module Static
    module Checks
      # Constants known to hold unshareable objects. Their
      # definitions live outside the scanned tree (or are swept
      # from it at setup), so the read site is the only place a
      # static pass can flag. Learned type aliases match only in
      # Sorbet type positions, where a constant can only name a
      # type—a class sharing a name stays quiet. Namespaces that
      # build constants with const_set at boot get their constant
      # reads flagged too: the values never pass through a literal
      # the analyzer could classify.
      class UnshareableReads < Base
        explain :sorbet_type_alias,
          severity: :warning,
          message: "read of %{name}, a Sorbet type alias that " \
                   "is not Ractor-shareable",
          why: "T.type_alias wraps its block in an unfrozen " \
               "T::Private::Types::TypeAlias that also memoizes " \
               "on first use, so a non-main Ractor evaluating " \
               "the reference raises Ractor::IsolationError. " \
               "sig blocks evaluate lazily, on the first call " \
               "of the method they annotate, so the raise can " \
               "surface there too.",
          fix: "Evaluate sigs at boot on the main Ractor " \
               "(T::Utils.run_all_sig_blocks) and avoid runtime " \
               "T.let casts against the alias on Ractor code " \
               "paths, or rebind the constant to a deeply " \
               "shareable equivalent at boot."

        explain :dynamic_constant,
          severity: :warning,
          message: "read of %{name}, a constant its namespace " \
                   "defines dynamically at boot",
          why: "The owning namespace binds this constant with " \
               "const_set from runtime data, so no literal ever " \
               "reaches the analyzer; loaders of this shape " \
               "typically bind unfrozen strings or hashes, which " \
               "a non-main Ractor cannot read from a constant.",
          fix: "Make each value shareable as it is bound " \
               "(Ractor.make_shareable) or hold the data in a " \
               "frozen registry instead of loose constants."

        KNOWN = Ractor.make_shareable(
          {"T::Boolean" => :sorbet_type_alias}
        )

        # Stub generators write rbi definitions fully qualified on
        # one line, so a regex sweep is enough there.
        ALIAS_DEFINITION =
          /^\s*((?:[A-Z]\w*::)*[A-Z]\w*)\s*=\s*T\.type_alias\b/

        VALUE_NAME = /\A[A-Z][A-Z0-9_]*\z/

        class << self
          attr_reader :learned, :dynamic

          # Both hold names as segment arrays, written eagerly and
          # kept shareable so parallel scans read them from
          # non-main Ractors.
          def learned=(names)
            @learned = Ractor.make_shareable( # audition:disable
              names.uniq.group_by(&:last)
            )
          end

          def dynamic=(names)
            @dynamic = Ractor.make_shareable( # audition:disable
              names.uniq
            )
          end

          # Sweeps the tree for type-alias assignments and for
          # namespaces that const_set under a computed name.
          # Ruby sources are parsed so definitions keep their
          # nesting; rbi files are line-scanned.
          def learn(paths, progress: Progress::SILENT)
            aliases = []
            owners = []
            paths.each do |path|
              progress.tick
              source = begin
                File.read(path)
              rescue SystemCallError
                next
              end
              if path.end_with?(".rbi")
                source.scan(ALIAS_DEFINITION) do |(name)|
                  aliases << name.split("::")
                end
              else
                result = Prism.parse(source)
                next unless result.success?

                sweep(result.value, [], aliases, owners)
              end
            end
            self.learned = aliases
            self.dynamic = owners
          end

          private

          def sweep(node, nesting, aliases, owners)
            case node
            when Prism::ClassNode, Prism::ModuleNode
              nesting = [*nesting, *segments(node.constant_path)]
            when Prism::ConstantWriteNode
              if alias_value?(node.value)
                aliases << [*nesting, node.name.to_s]
              end
            when Prism::ConstantPathWriteNode
              if alias_value?(node.value)
                aliases << [*nesting, *segments(node.target)]
              end
            when Prism::CallNode
              if dynamic_definer?(node) &&
                  (owner = owner_of(node, nesting))
                owners << owner
              end
            end
            node.compact_child_nodes.each do |child|
              sweep(child, nesting, aliases, owners)
            end
          end

          def segments(node)
            node.location.slice.delete_prefix("::").split("::")
          end

          def alias_value?(value)
            value.is_a?(Prism::CallNode) &&
              value.name == :type_alias &&
              value.receiver&.location&.slice
                &.delete_prefix("::") == "T"
          end

          # A literal name would be classifiable on its own; the
          # loader shape worth learning computes the name.
          def dynamic_definer?(node)
            return false unless node.name == :const_set

            name = node.arguments&.arguments&.first
            !(name.nil? ||
              name.is_a?(Prism::SymbolNode) ||
              name.is_a?(Prism::StringNode))
          end

          def owner_of(node, nesting)
            owner = case node.receiver
            when nil, Prism::SelfNode
              nesting
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              segments(node.receiver)
            end
            owner unless owner.nil? || owner.empty?
          end
        end

        self.learned = []
        self.dynamic = []

        on :call_node do |node|
          note_type_position(node)
        end

        on :constant_path_node, :constant_read_node do |node|
          examine(node)
        end

        def initialize(file)
          super
          @typed = Set.new
        end

        private

        def examine(node)
          name = node.location.slice.delete_prefix("::")
          if (key = KNOWN[name])
            flag(node, key, name: name)
          elsif @typed.include?(node.object_id) && alias_read?(name)
            flag(node, :sorbet_type_alias, name: name)
          elsif dynamic_read?(name)
            flag(node, :dynamic_constant, name: name)
          end
        end

        # The read has to line up with a definition's tail; a
        # definition swept without nesting only pins its own name,
        # a qualified one pins the namespace too.
        def tail_match?(read, full)
          overlap = [read.size, full.size].min
          full.last(overlap) == read.last(overlap)
        end

        def alias_read?(name)
          segments = name.split("::")
          self.class.learned[segments.last]&.any? do |full|
            tail_match?(segments, full)
          end
        end

        # Only SCREAMING_CASE reads count: a loader binds values,
        # and classes nested under the namespace stay quiet.
        def dynamic_read?(name)
          segments = name.split("::")
          return false if segments.size < 2 ||
            !segments.last.match?(VALUE_NAME)

          parent = segments[0..-2]
          self.class.dynamic.any? do |owner|
            tail_match?(parent, owner)
          end
        end

        # Constants under a sig block or a T type argument name
        # types, so learned aliases may match there.
        def note_type_position(node)
          if node.name == :sig
            mark(node.block)
          elsif t_receiver?(node)
            case node.name
            when :let, :cast, :assert_type!
              mark(node.arguments&.arguments&.dig(1))
            when :nilable, :any, :all, :class_of, :type_alias
              node.arguments&.arguments&.each { |arg| mark(arg) }
              mark(node.block)
            end
          end
        end

        def t_receiver?(node)
          receiver = node.receiver
          case receiver
          when Prism::ConstantReadNode
            receiver.name == :T
          when Prism::ConstantPathNode
            receiver.location.slice.delete_prefix("::") == "T"
          else
            false
          end
        end

        def mark(node)
          return if node.nil?

          case node
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            return @typed << node.object_id
          end
          node.each_child_node { |child| mark(child) }
        end
      end
    end
  end
end
