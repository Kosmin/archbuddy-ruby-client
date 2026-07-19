# frozen_string_literal: true

require "prism"

# The L18 escape battery — the 13 P1 prototype cases ported verbatim as
# named examples, PLUS the pinned P2 sub-rule (#13-bis): case-on-own-param
# type dispatch is NOT an escape. Escape is a property of the CALLEE'S
# DEFINITION, never of a call site.
RSpec.describe Archbuddy::Collect::Adapters::Ruby::EscapeScanner do
  R = Archbuddy::Collect::Adapters::Ruby unless defined?(R)

  def escapes?(src)
    program = Prism.parse(src).value
    def_node = program.statements.body.find { |n| n.is_a?(Prism::DefNode) }
    described_class.escapes?(def_node)
  end

  # --- the 13-case battery ------------------------------------------------

  it "yields_plain: a plain yield escapes" do
    expect(escapes?("def a; yield; end")).to be(true)
  end

  it "yields_in_block: a yield inside an inline block escapes (the method's block)" do
    expect(escapes?("def a; items.each { |i| yield i }; end")).to be(true)
  end

  it "yield_inside_lambda: a yield inside a lambda escapes (still the method's block)" do
    expect(escapes?("def a; f = -> { yield }; f.call; end")).to be(true)
  end

  it "checks_block: block_given? escapes (and iterator? likewise)" do
    expect(escapes?("def a; return 1 unless block_given?; 2; end")).to be(true)
    expect(escapes?("def a; iterator? ? 1 : 2; end")).to be(true)
  end

  it "calls_block: a declared block param invoked with .call escapes" do
    expect(escapes?("def a(&blk); blk.call(1); end")).to be(true)
  end

  it "passes_block: a declared block param forwarded onward escapes" do
    expect(escapes?("def a(&blk); other(&blk); end")).to be(true)
  end

  it "anonymous_pass: an anonymous & param forwarded onward escapes" do
    expect(escapes?("def a(&); other(&); end")).to be(true)
  end

  it "unused_block: a declared-but-unused &blk is NOT an escape" do
    expect(escapes?("def a(&blk); 1; end")).to be(false)
  end

  it "callable_param_call: a positional/optional/keyword param .call escapes" do
    expect(escapes?("def a(cb); cb.call(2); end")).to be(true)
    expect(escapes?("def a(cb = nil); cb.call; end")).to be(true)
    expect(escapes?("def a(cb:); cb.call; end")).to be(true)
  end

  it "dynamic_dispatch: a non-literal meta-send escapes" do
    expect(escapes?("def a(m); send(m); end")).to be(true)
    expect(escapes?("def a(m); public_send(m, 1); end")).to be(true)
  end

  it "literal_send: send with a literal Symbol/String arg is NOT an escape " \
     "(MetaSendProbe resolves it)" do
    expect(escapes?("def a; send(:foo); end")).to be(false)
    expect(escapes?('def a; public_send("bar", 1); end')).to be(false)
  end

  it "lambda_return: building/returning a lambda is NOT an escape (arity 1)" do
    src = "def a; -> { 1 }; end"
    expect(escapes?(src)).to be(false)
    # cross-check the arity half of the battery verdict
    classes = R::OutcomeArityCounter.classes(
      Prism.parse(src).value.statements.body.first.body
    )
    expect(R::OutcomeArityCounter.arity(classes)).to eq(1)
  end

  it "stdlib inline-block call site is NOT an escape (structural: no in-tree callee def)" do
    expect(escapes?("def a; arr.each { |x| x * 2 }; end")).to be(false)
    expect(escapes?("def a; arr.map { |x| x }.select { |x| x }; end")).to be(false)
  end

  # --- #13-bis: the pinned P2 sub-rule -------------------------------------

  it "case-on-own-param type dispatch is NOT an escape AND keeps arity 2 " \
     "(the prepare_variables shape — guard R2 pin)" do
    src = <<~RUBY
      def prepare_variables(variables_param)
        case variables_param
        when String
          JSON.parse(variables_param) || {}
        when Hash
          variables_param
        when ActionController::Parameters
          variables_param.to_unsafe_hash
        when nil
          {}
        else
          raise ArgumentError, "Unexpected parameter: \#{variables_param}"
        end
      end
    RUBY
    expect(escapes?(src)).to be(false)
    classes = R::OutcomeArityCounter.classes(
      Prism.parse(src).value.statements.body.first.body
    )
    expect(classes).to contain_exactly(:value, :raise)
    expect(R::OutcomeArityCounter.arity(classes)).to eq(2)
  end

  # --- degenerate shapes -----------------------------------------------------

  it "nil/empty body -> false (no evidence, never fabricated true)" do
    expect(described_class.escapes?(nil)).to be(false)
    expect(escapes?("def a; end")).to be(false)
  end

  it "a def whose only content is a nested def scans as empty (stop-at-DefNode)" do
    src = <<~RUBY
      def outer
        def inner
          yield
        end
      end
    RUBY
    expect(escapes?(src)).to be(false)
  end

  # --- the ONE shared dispatch predicate ---------------------------------------

  it "delegates dispatch-arg literalness to the hoisted Vocab predicate" do
    lit = Prism.parse("send(:foo)").value.statements.body.first
    dyn = Prism.parse("send(m)").value.statements.body.first
    expect(R::Vocab.literal_dispatch_arg?(lit)).to be(true)
    expect(R::Vocab.literal_dispatch_arg?(dyn)).to be(false)
    expect(R::Vocab.literal_dispatch_arg?(nil)).to be(false)
  end

  # --- MethodEntry threading (all three mint kinds stamped uniformly) -----------

  describe "MethodEntry threading" do
    def table_for(src, rel_file: "app/models/x.rb")
      table = R::SymbolTable.new
      Prism.parse(src).value.accept(R::DefinitionPass.new(table, rel_file))
      table
    end

    it "stamps escapes on def entries (true and default-false)" do
      table = table_for(<<~RUBY)
        class Finder
          def find_each
            @items.each { |i| yield i }
          end

          def plain
            1
          end
        end
      RUBY
      expect(table.method_for("Finder#find_each").escapes).to be(true)
      expect(table.method_for("Finder#plain").escapes).to be(false)
    end

    it "stamps escapes on minted Grape endpoint entries" do
      table = table_for(<<~RUBY, rel_file: "app/api/api.rb")
        class Api < Grape::API
          get "/ping" do
            pong
          end
        end
      RUBY
      expect(table.method_for("Api#GET[0]").escapes).to be(false)
    end

    it "stamps escapes on minted rake task entries" do
      table = table_for("task :cleanup do\n  Cleaner.purge\nend\n",
                        rel_file: "lib/tasks/cleanup.rake")
      entry = table.methods.values.find { |m| m.fq_symbol.include?("cleanup") }
      expect(entry.escapes).to be(false)
    end

    it "defaults escapes false on hand-built entries" do
      entry = R::SymbolTable::MethodEntry.new(fq_symbol: "X#y", name: "y")
      expect(entry.escapes).to be(false)
    end
  end
end
