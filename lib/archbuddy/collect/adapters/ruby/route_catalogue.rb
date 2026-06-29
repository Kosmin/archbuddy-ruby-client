# frozen_string_literal: true

require "prism"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Pass-1 Rails-routes entrypoint seeder (W4). Walks Prism ASTs looking
        # for `Rails.application.routes.draw` blocks, then collects:
        #
        #   - Explicit `to: "controller#action"` strings (StringNode)
        #   - `resources :name` / `resource :name` RESTful expansion (7/6 actions)
        #     honouring `only:`/`except:` keyword filters
        #
        # One level of `namespace`/`scope module:` nesting is understood; deeper
        # nesting and dynamic module expressions are silently skipped (never
        # fabricate — L2).
        #
        # This is NOT a Probe — it emits NO edges and NO new nodes. It feeds
        # (controller_fq, action) pairs into the SymbolTable so EntrypointDetector
        # can confirm them as entrypoints IFF `table.method?` is true (L2 gate).
        class RouteCatalogue < Prism::Visitor
          # Full RESTful action sets per DSL keyword (Rails convention).
          RESOURCES_ACTIONS = %w[index show new create edit update destroy].freeze
          RESOURCE_ACTIONS  = %w[show new create edit update destroy].freeze

          # Route verbs that carry a `to:` argument.
          ROUTE_VERBS = %w[get post put patch delete match root].freeze

          def initialize(table, rel_file)
            @table    = table
            @rel_file = rel_file
            # Namespace/module prefix stack (one level of nesting understood).
            # Each entry is a String module segment (e.g. "Admin").
            @ns_stack = []
            # Whether we are currently inside a routes.draw block.
            @in_routes = false
            super()
          end

          # Walk only when we encounter the routes.draw call. Other files are a
          # no-op (the visitor will skip all nodes quickly).
          def visit_call_node(node)
            if !@in_routes && routes_draw_call?(node)
              # Enter the draw block scope.
              @in_routes = true
              begin
                # Walk the block body.
                node.block&.body && visit(node.block.body)
              ensure
                @in_routes = false
              end
              return # do not super — we manually walked the body above
            end

            return super unless @in_routes

            # Inside a routes.draw block: handle each DSL form.
            if explicit_route_call?(node)
              collect_explicit_to(node)
            elsif resources_call?(node)
              collect_resources(node)
            elsif namespace_or_scope_call?(node)
              collect_namespaced(node)
              return # collect_namespaced already walked the body with the namespace segment pushed; do NOT double-walk via super (would re-seed nested routes with an empty namespace stack)
            end

            super
          end

          private

          # -----------------------------------------------------------------
          # routes.draw detection
          # -----------------------------------------------------------------

          # Matches `Rails.application.routes.draw do … end` or just
          # `routes.draw { … }` or any chain ending in `.draw` with a block.
          def routes_draw_call?(node)
            node.name.to_s == "draw" &&
              !node.block.nil? &&
              receiver_ends_with_routes?(node.receiver)
          end

          def receiver_ends_with_routes?(receiver)
            return false if receiver.nil?

            case receiver
            when Prism::CallNode
              receiver.name.to_s == "routes" ||
                receiver_ends_with_routes?(receiver.receiver)
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              false
            else
              false
            end
          end

          # -----------------------------------------------------------------
          # Explicit `to:` route
          # -----------------------------------------------------------------

          def explicit_route_call?(node)
            ROUTE_VERBS.include?(node.name.to_s) && has_to_string?(node)
          end

          def collect_explicit_to(node)
            to_value = extract_to_string(node) or return
            ctrl_name, action = to_value.split("#", 2)
            return if ctrl_name.nil? || action.nil? || action.empty?

            controller_fq = controller_class_fq(ctrl_name)
            seed(controller_fq, action)
          end

          # -----------------------------------------------------------------
          # `resources :name` / `resource :name`
          # -----------------------------------------------------------------

          def resources_call?(node)
            name = node.name.to_s
            (name == "resources" || name == "resource") && has_name_arg?(node)
          end

          def collect_resources(node)
            resource_name = extract_name_arg(node) or return
            singular = node.name.to_s == "resource"
            actions  = base_actions(singular)
            actions  = apply_only_except(actions, node)
            controller_fq = controller_class_fq_from_resource(resource_name, singular)

            actions.each { |action| seed(controller_fq, action) }

            # Walk nested block (e.g. `resources :posts do; resources :comments; end`).
            # We recurse into nested `resources`/`resource` calls via super.
          end

          def base_actions(singular)
            singular ? RESOURCE_ACTIONS.dup : RESOURCES_ACTIONS.dup
          end

          # -----------------------------------------------------------------
          # `namespace :admin do … end` / `scope module: "admin" do … end`
          # -----------------------------------------------------------------

          def namespace_or_scope_call?(node)
            name = node.name.to_s
            (name == "namespace" || name == "scope") && !node.block.nil?
          end

          def collect_namespaced(node)
            mod = extract_namespace_module(node) or return # skip dynamic/missing
            @ns_stack.push(mod)
            begin
              # Walk the block body directly. Using visit(node.block.body) re-
              # enters visit_call_node for each nested route call while the
              # namespace segment is on the stack.
              visit(node.block.body) if node.block&.body
            ensure
              @ns_stack.pop
            end
          end

          # -----------------------------------------------------------------
          # Seeding into the SymbolTable
          # -----------------------------------------------------------------

          def seed(controller_fq, action)
            fq = "#{controller_fq}##{action}"
            return unless @table.method?(fq) # NEVER-FABRICATE gate (L2)

            @table.add_routed_action(controller_fq, action)
          end

          # -----------------------------------------------------------------
          # Controller FQ derivation (Rails convention)
          # -----------------------------------------------------------------

          # `"graphql"` → `"GraphqlController"`
          # `"admin/users"` → with ns_stack [] → `"Admin::UsersController"`
          # ns_stack ["Admin"] + `"users"` → `"Admin::UsersController"`
          def controller_class_fq(ctrl_name_raw)
            # Strip trailing `/`-prefixed path; use the leading namespace prefix
            # from the DSL string, combined with the current @ns_stack.
            segments = ctrl_name_raw.split("/").map { |s| camelize(s) }
            ns_prefix = @ns_stack.map { |s| camelize(s) }
            all = (ns_prefix + segments)
            all[-1] = "#{all[-1]}Controller" unless all.empty?
            all.join("::")
          end

          # For `resources :tiers` → `TiersController` (plural name as-is);
          # for `resource :session` → `SessionController`.
          # Resource name arg is a symbol/string like `:tiers` or `"tiers"`.
          def controller_class_fq_from_resource(resource_name, _singular)
            segments = resource_name.split("/").map { |s| camelize(s) }
            ns_prefix = @ns_stack.map { |s| camelize(s) }
            all = (ns_prefix + segments)
            all[-1] = "#{all[-1]}Controller" unless all.empty?
            all.join("::")
          end

          def camelize(str)
            str.split("_").map(&:capitalize).join
          end

          # -----------------------------------------------------------------
          # Argument extraction helpers
          # -----------------------------------------------------------------

          # True when the call node has a keyword hash arg containing a `to:` key
          # whose value is a StringNode.
          def has_to_string?(node)
            !extract_to_string(node).nil?
          end

          def extract_to_string(node)
            each_keyword_pair(node) do |key, value|
              return value.unescaped if key_named?(key, "to") && value.is_a?(Prism::StringNode)
            end
            nil
          end

          # True when the call node has at least one positional argument
          # (SymbolNode or StringNode).
          def has_name_arg?(node)
            !extract_name_arg(node).nil?
          end

          def extract_name_arg(node)
            return nil unless node.arguments

            node.arguments.arguments.each do |arg|
              case arg
              when Prism::SymbolNode
                return arg.value.to_s
              when Prism::StringNode
                return arg.unescaped
              end
            end
            nil
          end

          # Walk keyword hash args of `node`, yielding (key_node, value_node) pairs.
          def each_keyword_pair(node)
            return unless node.arguments

            node.arguments.arguments.each do |arg|
              next unless arg.is_a?(Prism::KeywordHashNode)

              arg.elements.each do |pair|
                next unless pair.is_a?(Prism::AssocNode)

                yield pair.key, pair.value
              end
            end
          end

          # True when a keyword key node carries the name `expected` (SymbolNode
          # `:to` or LabelNode `to:`).
          def key_named?(key_node, expected)
            case key_node
            when Prism::SymbolNode
              key_node.value.to_s == expected
            when Prism::StringNode
              key_node.unescaped == expected
            else
              # Label nodes (`:to` in keyword syntax) expose #value or slice.
              key_node.slice.delete_suffix(":") == expected
            end
          end

          # Extract `only:` / `except:` arrays from a `resources` call.
          def apply_only_except(actions, node)
            only   = extract_symbol_array(node, "only")
            except = extract_symbol_array(node, "except")

            if only
              actions & only
            elsif except
              actions - except
            else
              actions
            end
          end

          def extract_symbol_array(node, key_name)
            each_keyword_pair(node) do |key, value|
              next unless key_named?(key, key_name)

              return collect_symbol_string_array(value)
            end
            nil
          end

          # Collect an ArrayNode of SymbolNode/StringNode values as strings.
          def collect_symbol_string_array(node)
            return nil unless node.is_a?(Prism::ArrayNode)

            node.elements.filter_map do |el|
              case el
              when Prism::SymbolNode then el.value.to_s
              when Prism::StringNode then el.unescaped
              end
            end
          end

          # Extract the module name from `namespace :admin` or `scope module: "api"`.
          def extract_namespace_module(node)
            case node.name.to_s
            when "namespace"
              extract_name_arg(node)
            when "scope"
              each_keyword_pair(node) do |key, value|
                if key_named?(key, "module")
                  return value.unescaped if value.is_a?(Prism::StringNode)
                  return value.value.to_s if value.is_a?(Prism::SymbolNode)
                end
              end
              nil
            end
          end
        end
      end
    end
  end
end
