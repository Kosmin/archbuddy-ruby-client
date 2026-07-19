# frozen_string_literal: true

require "prism"

# Layer-2 tail-call / ivar-memo arity-inheritance fixpoint (v0.12 CL-B,
# L16/L17). Bare self-call + ivar union ONLY — receiver'd-call resolution is
# the R4 refusal (that would re-implement the Resolver inside Pass 1).
RSpec.describe Archbuddy::Collect::Adapters::Ruby::ArityResolver do
  R = Archbuddy::Collect::Adapters::Ruby unless defined?(R)

  def resolve(src, rel_file: "app/models/x.rb")
    table = R::SymbolTable.new
    Prism.parse(src).value.accept(R::DefinitionPass.new(table, rel_file))
    described_class.new(table).resolve
  end

  it "resolves the memoized forwarder 1->2 (the current_merchant_user shape, L16)" do
    arities = resolve(<<~RUBY)
      class Sessions
        def current_user
          @u ||= authenticate
        end

        def authenticate
          return nil unless ok?
          find_user
        end
      end
    RUBY
    # authenticate: {nil} + ref(ok?)-guard tail... its own set is {nil, value}
    expect(arities["Sessions#authenticate"]).to eq(2)
    # the forwarder INHERITS the delegate's outcomes: {value} U {nil, value} = 2
    expect(arities["Sessions#current_user"]).to eq(2)
  end

  it "resolves the explicit memo-guard forwarder shape through the ivar union" do
    arities = resolve(<<~RUBY)
      class Sessions
        def current_user
          return @u if @u
          @u = authenticate
        end

        def authenticate
          return nil unless ok?
          find_user
        end
      end
    RUBY
    expect(arities["Sessions#current_user"]).to eq(2)
  end

  it "folds mutually-tail-calling defs (cycle) to :value, arity 1, under the cap" do
    arities = resolve(<<~RUBY)
      class Loop
        def a
          b
        end

        def b
          a
        end
      end
    RUBY
    expect(arities["Loop#a"]).to eq(1)
    expect(arities["Loop#b"]).to eq(1)
  end

  it "folds a self-recursive def to :value, arity 1 (opaque-value contract)" do
    arities = resolve(<<~RUBY)
      class Rec
        def f
          f
        end
      end
    RUBY
    expect(arities["Rec#f"]).to eq(1)
  end

  it "folds a REF to an out-of-tree name to :value, arity from the remaining classes" do
    arities = resolve(<<~RUBY)
      class Caller
        def wrap
          return nil unless ready?
          some_helper_defined_elsewhere
        end
      end
    RUBY
    expect(arities["Caller#wrap"]).to eq(2) # {nil} U {value}
  end

  it "mirrors resolver tier R3: instance first, then singleton, same owner" do
    arities = resolve(<<~RUBY)
      class Owner
        def wrap
          helper
        end

        def self.helper
          nil
        end
      end
    RUBY
    # no instance Owner#helper -> falls to singleton Owner.helper ({nil})
    expect(arities["Owner#wrap"]).to eq(1)
    expect(arities["Owner.helper"]).to eq(1)
  end

  it "resolves owner-less (top-level) defs against the bare name" do
    arities = resolve(<<~RUBY, rel_file: "script.rb")
      def outer
        inner
      end

      def inner
        true
      end
    RUBY
    expect(arities["outer"]).to eq(1) # {true}
    expect(arities["inner"]).to eq(1)
  end

  it "propagates :unresolved through a forwarder to nil (never fabricated)" do
    arities = resolve(<<~RUBY)
      class Fuzzy
        def wrap
          weird
        end

        def weird
          alias a b
        end
      end
    RUBY
    expect(arities["Fuzzy#weird"]).to be_nil
    expect(arities["Fuzzy#wrap"]).to be_nil
  end

  it "returns nil for hand-built entries with no outcome_classes (unresolved, absent downstream)" do
    table = R::SymbolTable.new
    table.add_method(R::SymbolTable::MethodEntry.new(fq_symbol: "X#y", name: "y"))
    expect(described_class.new(table).resolve).to eq("X#y" => nil)
  end

  it "returns {} on an empty SymbolTable (no iteration, nothing fabricated)" do
    expect(described_class.new(R::SymbolTable.new).resolve).to eq({})
  end

  it "resolves a two-hop forwarder chain (fixpoint, not single-pass)" do
    arities = resolve(<<~RUBY)
      class Chain
        def a
          b
        end

        def b
          c
        end

        def c
          return nil unless ok?
          true
        end
      end
    RUBY
    expect(arities["Chain#c"]).to eq(2) # {nil, true}
    expect(arities["Chain#b"]).to eq(2)
    expect(arities["Chain#a"]).to eq(2)
  end

  it "property: NO input yields arity 0 (floor >= 1 or nil, L16)" do
    arities = resolve(<<~RUBY)
      class Deg
        def empty_body; end

        def raise_only
          raise Boom
        end

        def cycle_a
          cycle_b
        end

        def cycle_b
          cycle_a
        end

        def unresolved_tail
          alias a b
        end
      end
    RUBY
    arities.each_value do |arity|
      expect(arity.nil? || arity >= 1).to be(true), "expected >=1 or nil, got #{arity.inspect}"
    end
    expect(arities["Deg#empty_body"]).to eq(1) # {nil}
    expect(arities["Deg#raise_only"]).to eq(1) # {raise}
    expect(arities["Deg#unresolved_tail"]).to be_nil
  end

  it "caps every produced arity at the intrinsic taxonomy size 5" do
    arities = resolve(<<~RUBY)
      class Wide
        def all_five
          return nil if a?
          return true if b?
          return false if c?
          raise Boom if d?
          "value"
        end
      end
    RUBY
    expect(arities["Wide#all_five"]).to eq(5)
    arities.each_value { |a| expect(a.nil? || a <= 5).to be(true) }
  end
end
