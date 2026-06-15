# frozen_string_literal: true

require "prism"
require_relative "vocab"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Pure tiered decision logic (D24). Given a call site and its enclosing
        # context, decide what the call resolves to WITHOUT touching the AST
        # walk or mutating state — so each tier is independently testable.
        #
        # The single source of truth for "what kind of thing did this call hit".
        # NEVER fabricates an edge: an unknown call routes to the shared external
        # sink, metaprogramming yields :metaprogramming (no edge), operators are
        # dropped (:drop).
        class RubyResolver
          # Context for a single call site.
          #   name              => Symbol/String method name
          #   receiver          => the Prism receiver node (or nil for implicit self)
          #   enclosing_class   => fq name of the class the call lexically sits in (or nil)
          #   table             => SymbolTable
          CallContext = Struct.new(
            :name, :receiver, :enclosing_class, :table, keyword_init: true
          )

          # A resolution outcome.
          #   tier      => Symbol describing which rule fired (for debugging/tests)
          #   action    => :edge | :drop | :metaprogramming | :external
          #   target_fq => fq symbol of the resolved app target (for :edge to a known method)
          #   kind      => contract node kind for the *target* when synthesizing it
          #                (:db_op / :external); nil when target is an existing method node
          Resolution = Struct.new(
            :tier, :action, :target_fq, :kind, keyword_init: true
          )

          def initialize(table)
            @table = table
          end

          # @param ctx [CallContext]
          # @return [Resolution]
          def resolve(ctx)
            name = ctx.name.to_s

            # R0: operator deny-list — drop entirely (D36).
            return drop(:operator) if Vocab.operator?(name)

            # R1: metaprogramming — flag, emit NO edge (we can't know the target).
            return meta(:metaprogramming) if Vocab.metaprogramming?(name)

            # R2: db_op via CLASS CONTEXT. The verified gotcha: `where` inside
            # `def self.x` of an AR subclass has receiver = nil (implicit self),
            # so we must consult the enclosing class, not the receiver shape.
            if active_record_context?(ctx) && Vocab.active_record_method?(name)
              return Resolution.new(
                tier: :db_op_class_context, action: :external, # synthesized sink-like node
                target_fq: db_op_symbol(ctx, name), kind: "db_op"
              )
            end

            # R3: implicit-self / explicit-self call to a method on the enclosing
            # class. e.g. `tax` inside `Invoice#total` -> Invoice#tax (if known).
            if self_receiver?(ctx.receiver) && ctx.enclosing_class
              instance_fq = "#{ctx.enclosing_class}##{name}"
              singleton_fq = "#{ctx.enclosing_class}.#{name}"
              if @table.method?(instance_fq)
                return edge(:self_instance, instance_fq)
              elsif @table.method?(singleton_fq)
                return edge(:self_singleton, singleton_fq)
              end
            end

            # R4: app `Const.method` / `Const::Path.method` -> known method node.
            if (const_fq = constant_receiver_fq(ctx.receiver))
              singleton_fq = "#{const_fq}.#{name}"
              instance_fq  = "#{const_fq}##{name}"

              # db_op when the constant is a known AR class (e.g. User.where).
              if @table.active_record_class?(const_fq) && Vocab.active_record_method?(name)
                return Resolution.new(
                  tier: :db_op_const_receiver, action: :external,
                  target_fq: "#{const_fq}.#{name}", kind: "db_op"
                )
              end

              return edge(:const_singleton, singleton_fq) if @table.method?(singleton_fq)
              return edge(:const_instance, instance_fq)    if @table.method?(instance_fq)
            end

            # R9: everything unresolved -> the single shared external sink.
            Resolution.new(tier: :external, action: :external, target_fq: nil, kind: "external")
          end

          private

          def active_record_context?(ctx)
            ctx.enclosing_class && @table.active_record_class?(ctx.enclosing_class)
          end

          # A db_op target symbol in real space. For implicit-self AR calls we key
          # it by the enclosing class so `Invoice.where` and `Order.where` are
          # distinct db_op nodes; the bare method name keeps them readable.
          def db_op_symbol(ctx, name)
            "#{ctx.enclosing_class}.#{name}"
          end

          def self_receiver?(receiver)
            receiver.nil? || receiver.is_a?(Prism::SelfNode)
          end

          # If the receiver is a constant (Foo) or constant path (Foo::Bar),
          # return its fq name; else nil.
          def constant_receiver_fq(receiver)
            return nil if receiver.nil?

            case receiver
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              receiver.slice
            end
          end

          def edge(tier, target_fq)
            Resolution.new(tier: tier, action: :edge, target_fq: target_fq, kind: nil)
          end

          def drop(tier)
            Resolution.new(tier: tier, action: :drop, target_fq: nil, kind: nil)
          end

          def meta(tier)
            Resolution.new(tier: tier, action: :metaprogramming, target_fq: nil, kind: nil)
          end
        end
      end
    end
  end
end
