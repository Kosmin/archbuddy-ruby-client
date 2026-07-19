# frozen_string_literal: true

require "prism"

# Layer-1 outcome-class taxonomy (v0.12 L16, rules 1-9 of the D3 rule set).
# Synthetic bodies only; the REAL app-mgmt anchor confirmation lives in
# spec/collect/arity_anchor_fixture_spec.rb (CL-D).
RSpec.describe Archbuddy::Collect::Adapters::Ruby::OutcomeArityCounter do
  R = Archbuddy::Collect::Adapters::Ruby unless defined?(R)

  def classes_for(src)
    program = Prism.parse(src).value
    def_node = program.statements.body.find { |n| n.is_a?(Prism::DefNode) }
    described_class.classes(def_node.body)
  end

  def arity_for(src)
    described_class.arity(classes_for(src))
  end

  # --- rule 1: exit set = implicit tail + explicit returns + raise evidence

  it "classifies a nil body as {nil}, arity 1 (truthful, floor holds)" do
    expect(classes_for("def x; end")).to eq([:nil])
    expect(described_class.classes(nil)).to eq([:nil])
    expect(arity_for("def x; end")).to eq(1)
  end

  it "unions explicit returns with the implicit tail" do
    src = <<~RUBY
      def x
        return nil unless ok?
        true
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:nil, :true)
    expect(arity_for(src)).to eq(2)
  end

  it "counts a block's `return` as a method return (descends into blocks)" do
    src = <<~RUBY
      def x
        items.each { |i| return true if i }
        nil
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:true, :nil)
  end

  it "does NOT count a lambda's own `return` as a method return" do
    src = <<~RUBY
      def x
        f = -> { return true }
        f
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:value)
    expect(arity_for(src)).to eq(1)
  end

  it "stops at a nested DefNode (the inner def is its own entry)" do
    src = <<~RUBY
      def x
        def y
          return false
        end
      end
    RUBY
    # the inner def expression evaluates to a method-name symbol -> VALUE;
    # the inner `return false` never leaks into the outer set
    expect(classes_for(src)).to eq([:value])
  end

  # --- rule 2: tail flattening ------------------------------------------------

  it "contributes every if/else arm tail" do
    src = <<~RUBY
      def x
        if a?
          true
        elsif b?
          false
        else
          nil
        end
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:true, :false, :nil)
    expect(arity_for(src)).to eq(3)
  end

  it "adds an implicit NIL for an armless if/unless/case tail" do
    expect(classes_for("def x; if a?; true; end; end")).to contain_exactly(:true, :nil)
    expect(classes_for("def x; unless a?; false; end; end")).to contain_exactly(:false, :nil)
    expect(classes_for(<<~RUBY)).to contain_exactly(:value, :nil)
      def x
        case k
        when 1 then "one"
        end
      end
    RUBY
  end

  it "contributes every case/when arm tail; else replaces the implicit nil" do
    src = <<~RUBY
      def x
        case k
        when 1 then "a"
        when 2 then true
        else false
        end
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:value, :true, :false)
  end

  it "contributes case/in arm tails (pattern-match case)" do
    src = <<~RUBY
      def x
        case k
        in String then "s"
        in Integer then nil
        end
      end
    RUBY
    expect(classes_for(src)).to include(:value, :nil)
  end

  it "classifies a while/until/for tail as NIL" do
    expect(classes_for("def x; while a?; b; end; end")).to eq([:nil])
  end

  it "replaces the begin tail with the else tail and adds every rescue tail" do
    src = <<~RUBY
      def x
        begin
          work
        rescue A
          nil
        rescue B
          false
        else
          true
        end
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:true, :nil, :false)
  end

  it "keeps the begin tail when no else clause is present (def-level rescue)" do
    src = <<~RUBY
      def x
        compute
      rescue Boom
        nil
      end
    RUBY
    # compute is a bare self-call -> [:ref, :compute]; rescue tail -> :nil
    expect(classes_for(src)).to contain_exactly([:ref, :compute], :nil)
  end

  # --- rule 3: assignment tails classify by RHS --------------------------------

  it "classifies an assignment tail by its RHS (the `@x = nil` L3b shape)" do
    expect(classes_for("def x; @a = nil; end")).to eq([:nil])
    expect(classes_for("def x; a = JWT.decode(t); end")).to eq([:value])
  end

  # --- rule 4: memo-guard collapsing via intra-def ivar finalization ------------

  it "collapses the memo-guard + rescue shape at the return boundary (decoded_token)" do
    src = <<~RUBY
      def decoded_token
        return @decoded_token if defined?(@decoded_token)
        token = extract
        return @decoded_token = nil unless token
        @decoded_token = JWT.decode(token).first
      rescue JWT::DecodeError
        @decoded_token = nil
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:value, :nil)
    expect(arity_for(src)).to eq(2)
  end

  it "folds an ivar read never assigned in-def to opaque VALUE" do
    expect(classes_for("def x; @never_assigned; end")).to eq([:value])
  end

  # --- rule 5: boolean operators ------------------------------------------------

  it "classifies `a || b` as truthy(a) union classes(b)" do
    expect(classes_for("def x; find || nil; end")).to contain_exactly([:ref, :find], :nil)
    # a literal-nil lhs contributes nothing truthy
    expect(classes_for("def x; nil || true; end")).to eq([:true])
  end

  it "classifies `a && b` as {NIL} union classes(b) (documented approximation)" do
    expect(classes_for("def x; a? && true; end")).to contain_exactly(:nil, :true)
  end

  it "classifies `x ||= expr` as {VALUE} union classes(expr)" do
    expect(classes_for("def x; @m ||= compute; end")).to contain_exactly(:value, [:ref, :compute])
  end

  # --- rule 6: safe navigation ---------------------------------------------------

  it "classifies a safe-nav tail as provably {NIL, VALUE}" do
    src = <<~RUBY
      def x
        match = header.match(/token/)
        match&.[](1)
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:nil, :value)
    expect(arity_for(src)).to eq(2)
  end

  # --- rule 7: raise as its own class --------------------------------------------

  it "counts an unguarded raise, including guard shapes anywhere in the body" do
    expect(classes_for("def x; raise Boom; end")).to eq([:raise])
    expect(arity_for("def x; raise Boom; end")).to eq(1) # raise-only body, floor holds

    src = <<~RUBY
      def x
        raise ArgumentError if bad?
        "ok"
      end
    RUBY
    expect(classes_for(src)).to contain_exactly(:raise, :value)
  end

  it "does NOT count a raise lexically inside a rescue-guarded begin body" do
    src = <<~RUBY
      def x
        raise Boom
      rescue Boom
        nil
      end
    RUBY
    expect(classes_for(src)).to eq([:nil])
    expect(arity_for(src)).to eq(1)
  end

  it "still counts a raise inside a rescue clause body (it escapes)" do
    src = <<~RUBY
      def x
        work
      rescue StandardError => e
        raise e unless recoverable?
        nil
      end
    RUBY
    expect(classes_for(src)).to include(:raise, :nil)
  end

  it "treats `fail` like `raise` and guards the modifier-rescue expression" do
    expect(classes_for("def x; fail Boom; end")).to eq([:raise])
    # `risky rescue nil` -- the raise inside risky's expression is guarded
    expect(classes_for("def x; raise Boom rescue nil; end")).to eq([:nil])
  end

  # --- rule 8: literals ------------------------------------------------------------

  it "classifies the literal family" do
    expect(classes_for("def x; nil; end")).to eq([:nil])
    expect(classes_for("def x; true; end")).to eq([:true])
    expect(classes_for("def x; false; end")).to eq([:false])
    expect(classes_for('def x; "s"; end')).to eq([:value])
    expect(classes_for("def x; :sym; end")).to eq([:value])
    expect(classes_for("def x; 42; end")).to eq([:value])
    expect(classes_for("def x; [1]; end")).to eq([:value])
    expect(classes_for("def x;({}); end")).to eq([:value])
    expect(classes_for("def x; ->(a) { a }; end")).to eq([:value])
    expect(classes_for("def x; SomeConst; end")).to eq([:value])
    expect(classes_for("def x; self; end")).to eq([:value])
    expect(classes_for("def x; defined?(@a); end")).to eq([:value])
  end

  it "classifies `return a, b` as VALUE (an array)" do
    expect(classes_for("def x; return 1, 2; end")).to eq([:value])
  end

  it "classifies an opaque receiver'd call as VALUE" do
    expect(classes_for("def x; ENV.fetch('K', 'd'); end")).to eq([:value])
  end

  # --- rule 9 + the prism 1.9.0 vocabulary constraint ------------------------------

  it "classifies an unhandled node kind at a tail as :unresolved, arity nil (never guessed)" do
    src = <<~RUBY
      def x
        alias_method :a, :b
        alias a b
      end
    RUBY
    expect(classes_for(src)).to eq([:unresolved])
    expect(arity_for(src)).to be_nil
  end

  it "classifies an adjacent-string-literal tail truthfully as VALUE " \
     "(prism 1.9.0 has no StringConcatNode; it parses as InterpolatedStringNode)" do
    expect(Prism.const_defined?(:StringConcatNode)).to be(false)
    expect(classes_for(%(def x; "a" "b"; end))).to eq([:value])
  end

  # --- Layer-2 seam tokens -----------------------------------------------------------

  it "records a bare self-call tail as [:ref, name] (Layer-2 seam)" do
    expect(classes_for("def x; authenticate; end")).to eq([[:ref, :authenticate]])
  end

  it "folds leftover refs to VALUE in the shared arity derivation" do
    expect(described_class.arity([[:ref, :anything], :nil])).to eq(2)
    expect(described_class.arity([:value, :nil, :true, :false, :raise])).to eq(5)
    expect(described_class.arity([:unresolved, :value])).to be_nil
    expect(described_class.arity(nil)).to be_nil
  end

  # --- the three mint kinds all carry the field ---------------------------------------

  describe "MethodEntry threading (def / Grape endpoint / rake task mints)" do
    def table_for(src, rel_file: "app/models/x.rb")
      table = R::SymbolTable.new
      Prism.parse(src).value.accept(R::DefinitionPass.new(table, rel_file))
      table
    end

    it "stamps outcome_classes on plain def entries" do
      table = table_for(<<~RUBY)
        class Invoice
          def total
            return nil unless lines
            true
          end
        end
      RUBY
      expect(table.method_for("Invoice#total").outcome_classes)
        .to contain_exactly(:nil, :true)
    end

    it "stamps outcome_classes on minted Grape endpoint entries" do
      table = table_for(<<~RUBY, rel_file: "app/api/api.rb")
        class Api < Grape::API
          get "/ping" do
            nil
          end
        end
      RUBY
      expect(table.method_for("Api#GET[0]").outcome_classes).to eq([:nil])
    end

    it "stamps outcome_classes on minted rake task entries" do
      table = table_for("task :cleanup do\n  true\nend\n", rel_file: "lib/tasks/cleanup.rake")
      entry = table.methods.values.find { |m| m.fq_symbol.include?("cleanup") }
      expect(entry.outcome_classes).to eq([:true])
    end
  end
end
