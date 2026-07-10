# frozen_string_literal: true

require "set"
require "prism"
require_relative "../root_seeder"
require_relative "../root_dsl/rack_middleware"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootSeeders
          # Seeds Rack middleware `#call` methods as :middleware ingress
          # roots (v0.10 W2-B). An AST-SHAPED seeder: the Rack contract
          # (`def call(env)` arity, the `@app` write inside `initialize`,
          # and the `use`-registration) lives in the AST, so it re-walks
          # the fragments once.
          #
          # A class is a middleware root iff ALL THREE hold (L8 conjunction):
          #   1. it defines an instance `call` with exactly one required
          #      positional parameter (`def call(env)`),
          #   2. its `initialize` writes the `@app` ivar,
          #   3. a registration (`use Mw` / `config.middleware.use Mw` /
          #      `insert_before`/`insert_after`) naming the constant — by
          #      full fq or last segment — is found anywhere in the tree.
          #
          # NEVER-FABRICATE (L4): `#call(env)` alone is the WEAKEST ingress
          # signal, so a structural candidate WITHOUT a registration is
          # DECLINED. The final mark is additionally gated on
          # `table.method?("Fq#call")`.
          class MiddlewareSeeder < RootSeeder
            def self.root_type = :middleware

            def root_type = :middleware

            def seed(table, fragments: nil, root: nil)
              return if fragments.nil?

              scan = Scan.new
              fragments.each { |fragment| fragment.parsed_value.accept(scan) }

              scan.candidates.each do |class_fq|
                next unless registered?(scan.registrations, class_fq)

                call_fq = "#{class_fq}#call"
                next unless table.method?(call_fq) # L4 gate — decline

                table.mark_entrypoint(call_fq, :middleware)
              end
            end

            private

            # Registration names may be fully qualified ("Middleware::Auth")
            # or bare ("Auth" registered from inside the same namespace) —
            # match the candidate's fq or its last segment.
            def registered?(registrations, class_fq)
              registrations.include?(class_fq) ||
                registrations.include?(class_fq.split("::").last)
            end

            # One walk over all fragments collecting BOTH sides of the
            # conjunction: structural candidates (call/1 + @app-in-initialize,
            # per class fq) and the set of `use`-registered constant names.
            class Scan < Prism::Visitor
              attr_reader :registrations

              def initialize
                @namespace     = []
                @call_env      = Set.new # class fqs defining `call(env)`
                @app_ivar      = Set.new # class fqs whose initialize writes @app
                @registrations = Set.new # literal constant names named by a registration
                super()
              end

              # Candidates = the structural conjunction (both defs present).
              def candidates
                @call_env & @app_ivar
              end

              def visit_class_node(node)
                push_namespace(node.constant_path.slice) { super }
              end

              def visit_module_node(node)
                push_namespace(node.constant_path.slice) { super }
              end

              def visit_def_node(node)
                fq = current_namespace
                unless fq.empty?
                  @call_env << fq if RootDsl::RackMiddleware.call_env_def?(node)
                  @app_ivar << fq if RootDsl::RackMiddleware.initialize_assigns_app?(node)
                end
                super
              end

              def visit_call_node(node)
                if RootDsl::RackMiddleware.registration_call?(node)
                  RootDsl::RackMiddleware.registration_constants(node).each do |name|
                    @registrations << name
                  end
                end
                super
              end

              private

              def push_namespace(name)
                @namespace.push(name)
                yield
              ensure
                @namespace.pop
              end

              def current_namespace
                @namespace.join("::")
              end
            end
          end
        end
      end
    end
  end
end
