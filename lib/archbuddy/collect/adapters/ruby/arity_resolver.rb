# frozen_string_literal: true

require "set"
require_relative "outcome_arity_counter"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Layer-2 tail-call / ivar-memo arity-inheritance fixpoint (v0.12,
        # L16 Layer 2 + L17). Runs POST-Pass-1 over the complete SymbolTable
        # and PRE-Anonymizer (REF tokens carry REAL symbols — the K-5 trust
        # boundary forces client-side placement in RubyAdapter#assemble).
        #
        # Substitutes each [:ref, name] token (a bare self-call tail recorded
        # by the OutcomeArityCounter) with the callee's final class set, so
        # memoized FORWARDERS inherit their delegate's outcomes (the
        # `current_merchant_user` 1→2 motivating case — without this, the
        # user-found factor dies at the wrapper boundary).
        #
        # REF resolution mirrors resolver tier R3 EXACTLY (instance-then-
        # singleton on the same owner); an owner-less (top-level) def resolves
        # against the bare name. Misses (out-of-tree / metaprogrammed) fold to
        # :value — never fabricated.
        #
        # Fixpoint: iterate substitution until no set changes, with iteration
        # cap = table size (a cycle cannot progress past it; P1 measured
        # convergence in ONE pass on both target repos — the cap is a safety
        # net). On cap-hit or cycle participation, surviving REFs fold to
        # :value via the shared OutcomeArityCounter.arity derivation.
        #
        # Deliberately does NOT resolve receiver'd calls (the R4/R4.5
        # refusal): bare self-call + ivar union covers the measured forwarder
        # population (1.7% of nexus defs — exactly the L3c-critical set);
        # anything more re-implements the Resolver inside Pass 1.
        class ArityResolver
          def initialize(table)
            @table = table
          end

          # => { fq_symbol => Integer (1..5) | nil }
          # nil = unresolved (:unresolved present, or a hand-built entry with
          # no outcome_classes) → the field stays ABSENT downstream (L17).
          def resolve
            sets = {}
            @table.methods.each_value do |m|
              sets[m.fq_symbol] = m.outcome_classes
            end

            run_fixpoint(sets)

            sets.each_with_object({}) do |(fq, tokens), out|
              arity = OutcomeArityCounter.arity(tokens)
              # L16 floor invariant — deletion monotonicity is load-bearing
              # on it. Impossible by construction (an empty exit set cannot
              # be produced); guarded loudly rather than silently emitted.
              raise "arity floor violated for #{fq}: 0 (empty outcome set)" if arity&.zero?

              out[fq] = arity
            end
          end

          private

          def run_fixpoint(sets)
            cap = [sets.size, 1].max
            cap.times do
              changed = false
              sets.each do |fq, tokens|
                next if tokens.nil?
                next unless tokens.any? { |t| ref?(t) }

                substituted = substitute(fq, tokens, sets)
                if substituted != tokens
                  sets[fq] = substituted
                  changed  = true
                end
              end
              break unless changed
            end
          end

          def substitute(fq, tokens, sets)
            out = Set.new
            tokens.each do |t|
              if ref?(t)
                out.merge(ref_classes(fq, t.last, sets))
              else
                out << t
              end
            end
            out.to_a
          end

          # The callee's CURRENT class set; a self-reference or table miss
          # folds to :value (never fabricated). A callee with a nil set
          # (hand-built entry) is opaque → :value.
          def ref_classes(caller_fq, name, sets)
            callee_fq = resolve_callee(caller_fq, name)
            return [:value] if callee_fq.nil? || callee_fq == caller_fq

            callee_tokens = sets[callee_fq]
            return [:value] if callee_tokens.nil?

            callee_tokens
          end

          # Mirror of resolver tier R3: instance-then-singleton on the same
          # owner; owner-less defs resolve against the bare top-level name.
          def resolve_callee(caller_fq, name)
            entry = @table.method_for(caller_fq)
            return nil if entry.nil?

            owner = entry.owner_fq
            if owner
              instance_fq  = "#{owner}##{name}"
              singleton_fq = "#{owner}.#{name}"
              return instance_fq  if @table.method?(instance_fq)
              return singleton_fq if @table.method?(singleton_fq)
              nil
            else
              bare = name.to_s
              @table.method?(bare) ? bare : nil
            end
          end

          def ref?(token)
            token.is_a?(::Array) && token.first == :ref
          end
        end
      end
    end
  end
end
