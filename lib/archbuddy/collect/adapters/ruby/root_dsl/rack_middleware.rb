# frozen_string_literal: true

require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootDsl
          # Shared, pure recognizers for the Rack middleware shape (v0.10
          # W2-B). A class is a middleware CANDIDATE iff it defines an
          # instance `call` taking exactly one required positional (the env)
          # AND its `initialize` writes an `@app` ivar; it is SEEDED only
          # when a `use`-style REGISTRATION naming the constant is also
          # found somewhere in the tree (L8 conjunction — `#call(env)` alone
          # is the weakest signal, so a candidate without a registration is
          # DECLINED, never seeded — L4).
          #
          # Mirror of GrapeDsl/MixinDsl: pure functions over Prism nodes
          # only — no AST walk, no state, no app boot. The MiddlewareSeeder
          # owns the walk + the conjunction.
          module RackMiddleware
            # Rack registration verbs. `use` (Rack::Builder / config.ru /
            # `config.middleware.use`) plus the Rails middleware-stack
            # insertion verbs.
            REGISTRATION_METHODS = %w[use insert_before insert_after].freeze

            module_function

            # True when `def_node` is `def call(env)` — an INSTANCE def named
            # `call` with EXACTLY one required positional parameter and no
            # other parameter kinds. Optionals/rest/keywords/blocks make the
            # shape unprovable as the Rack contract -> false (decline).
            def call_env_def?(def_node)
              return false unless def_node.is_a?(Prism::DefNode)
              return false unless def_node.name.to_s == "call"
              return false unless def_node.receiver.nil? # instance method

              params = def_node.parameters
              return false if params.nil?

              params.requireds.length == 1 &&
                params.optionals.empty? && params.rest.nil? &&
                params.posts.empty? && params.keywords.empty? &&
                params.keyword_rest.nil? && params.block.nil?
            end

            # True when `def_node` is an `initialize` whose body writes the
            # `@app` ivar (`@app = app` / `@app ||= app`). The scan descends
            # into control flow but STOPS at nested class/module/def
            # boundaries (a nested scope's `@app` is not this initializer's).
            def initialize_assigns_app?(def_node)
              return false unless def_node.is_a?(Prism::DefNode)
              return false unless def_node.name.to_s == "initialize"

              assigns_app_ivar?(def_node.body)
            end

            # True when `node` is a middleware REGISTRATION call worth
            # scanning: named use/insert_before/insert_after on either a
            # self/implicit receiver (`use Mw` in a Rack::Builder block) or a
            # receiver chain ending in `middleware`
            # (`config.middleware.use Mw`,
            # `Rails.application.config.middleware.insert_before 0, Mw`).
            # Other receivers are DECLINED — an unrelated `client.use(x)`
            # never lands in the registration set.
            def registration_call?(node)
              return false unless node.is_a?(Prism::CallNode)
              return false unless REGISTRATION_METHODS.include?(node.name.to_s)

              recv = node.receiver
              return true if recv.nil? || recv.is_a?(Prism::SelfNode)

              recv.is_a?(Prism::CallNode) && recv.name.to_s == "middleware"
            end

            # The provable literal-constant names among a registration call's
            # arguments, in source order (e.g. ["Middleware::Auth"]). A
            # variable / string / computed argument is SKIPPED (declined) —
            # only a literal constant can name a seedable middleware class.
            def registration_constants(node)
              return [] unless node.is_a?(Prism::CallNode) && node.arguments

              node.arguments.arguments.filter_map do |arg|
                arg.slice if literal_constant?(arg)
              end
            end

            def literal_constant?(node)
              node.is_a?(Prism::ConstantReadNode) ||
                node.is_a?(Prism::ConstantPathNode)
            end

            # Recursive `@app`-write scan. Descends statements/conditionals
            # but stops at nested def/class/module scopes.
            def assigns_app_ivar?(node)
              return false if node.nil?

              case node
              when Prism::InstanceVariableWriteNode,
                   Prism::InstanceVariableOrWriteNode,
                   Prism::InstanceVariableAndWriteNode
                return true if node.name.to_s == "@app"
              when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode
                return false # a nested scope's ivars are not this initializer's
              end

              node.child_nodes.compact.any? { |child| assigns_app_ivar?(child) }
            end
          end
        end
      end
    end
  end
end
