# frozen_string_literal: true

require "prism"
require "tmpdir"
require "fileutils"

# v0.12 CL-D — the L16 MEASURE-ONCE anchor battery + the client-owned D7
# INPUT-side property gates.
#
# I2 provenance pins (measure once, never re-derive):
#   - client branch base: 3de9e09 (v0.10.0); engine L1 pin: 0aabcf8 (v0.8.0)
#   - anchor arities machine-confirmed by the P1 prototype on app-management
#     tree d2300cb5 (107/107 defs resolved) and nexus tree eba78fde
#     (17,223/17,238, 99.9%)
#   - G1 sign-off (2026-07-17): the conscious re-anchors these inputs feed —
#     the v0.6 2-step wrapper anchor re-anchors 2 -> 3; decoded_token MASS
#     reads as 10 calls / 6 unique edges under the L13 call-weighted unit;
#     V2c: #execute variety_mass cost 49 base / 57 with full anchor-subtree
#     arities (inside the predicted 50-70 window vs 2,342.67 today).
#   Those COST numbers are the ENGINE plan's D7 numeric gates — consumed
#   there, never recomputed here. This battery pins the EXTRACTION-level
#   inputs only (arity values + escape verdicts).
#
# Fixtures are SYNTHETIC bodies replicating only the PUBLISHED
# GraphqlController#execute anchor family + jwt_secret shapes (id-map
# secrecy: no real app-mgmt/nexus class symbols enter this repo).
RSpec.describe "L16 anchor fixtures + D7 input gates (v0.12 CL-D)" do
  R = Archbuddy::Collect::Adapters::Ruby unless defined?(R)

  ANCHOR_SRC = <<~RUBY
    class SyntheticAuth
      def execute
        result = schema_execute(query)
        render json: result
      rescue StandardError => e
        raise e unless dev_env?
        handle_error_in_development(e)
      end

      def decoded_token
        return @decoded_token if defined?(@decoded_token)
        token = extract_bearer_token(request)
        return @decoded_token = nil unless token
        @decoded_token = JWT.decode(token, jwt_secret, true, algorithm: "HS256").first
      rescue JWT::DecodeError
        @decoded_token = nil
      end

      def extract_bearer_token(request)
        header = request.headers["Authorization"]
        return nil unless header
        match = header.match(/^Bearer (.+)$/)
        match&.[](1)
      end

      def authenticate_from_token
        return nil unless decoded_token
        return nil unless merchant_user_id
        MerchantUser.find_by(id: merchant_user_id)
      rescue ActiveRecord::RecordNotFound
        nil
      end

      def current_merchant_user
        @current_merchant_user ||= authenticate_from_token
      end

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

      def jwt_secret
        ENV.fetch("JWT_SECRET", "fallback")
      end
    end
  RUBY

  def table_for(src, rel_file: "app/models/synthetic_auth.rb")
    table = R::SymbolTable.new
    Prism.parse(src).value.accept(R::DefinitionPass.new(table, rel_file))
    table
  end

  def anchor_arities
    @anchor_arities ||= begin
      table = table_for(ANCHOR_SRC)
      R::ArityResolver.new(table).resolve
    end
  end

  def anchor_entry(name)
    table_for(ANCHOR_SRC).method_for("SyntheticAuth##{name}")
  end

  # --- the measure-once anchor battery (L16 / L3b) --------------------------------

  it "decoded_token shape (memo guard + nil-guard + rescue-nil + assign tails) -> arity 2" do
    expect(anchor_arities["SyntheticAuth#decoded_token"]).to eq(2)
  end

  it "extract_bearer_token shape (nil guard + safe-nav tail) -> arity 2" do
    expect(anchor_arities["SyntheticAuth#extract_bearer_token"]).to eq(2)
  end

  it "authenticate_from_token shape (two nil guards + find tail + rescue nil) -> arity 2" do
    expect(anchor_arities["SyntheticAuth#authenticate_from_token"]).to eq(2)
  end

  it "prepare_variables shape (5-arm case, else raises) -> arity 2 AND escapes false" do
    expect(anchor_arities["SyntheticAuth#prepare_variables"]).to eq(2) # value|raise
    expect(anchor_entry("prepare_variables").escapes).to be(false)     # the P2 sub-rule pin
  end

  it "current_merchant_user memo-forwarder: Layer-1 arity 1, post-fixpoint 2 (the L16 headline)" do
    entry = anchor_entry("current_merchant_user")
    expect(R::OutcomeArityCounter.arity(entry.outcome_classes)).to eq(1) # Layer-1 undercount
    expect(anchor_arities["SyntheticAuth#current_merchant_user"]).to eq(2) # nil|value inherited
  end

  it "jwt_secret shape (single opaque ENV.fetch tail) -> arity 1" do
    expect(anchor_arities["SyntheticAuth#jwt_secret"]).to eq(1)
  end

  it "execute shape (render tail + rescue re-raise/handler) -> arity 2" do
    expect(anchor_arities["SyntheticAuth#execute"]).to eq(2) # value|raise
  end

  it "no anchor def escapes (the whole family is boundary-closed)" do
    table = table_for(ANCHOR_SRC)
    table.methods.each_value do |m|
      expect(m.escapes).to be(false), "expected #{m.fq_symbol} to be closed"
    end
  end

  # --- D7 input gate: arity floor (monotonicity's load-bearing precondition) --------

  it "arity floor: the degenerate battery yields >= 1 or absent, NEVER 0" do
    arities = R::ArityResolver.new(table_for(<<~RUBY)).resolve
      class Degenerate
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

        def unresolved_fold
          alias a b
        end
      end
    RUBY
    expect(arities["Degenerate#empty_body"]).to eq(1)
    expect(arities["Degenerate#raise_only"]).to eq(1)
    expect(arities["Degenerate#cycle_a"]).to eq(1)
    expect(arities["Degenerate#cycle_b"]).to eq(1)
    expect(arities["Degenerate#unresolved_fold"]).to be_nil
    arities.each_value { |a| expect(a.nil? || a >= 1).to be(true) }
  end

  # --- D7 input gate: firewall (internal refactor invisibility at extraction) --------

  it "firewall input: same contract, different internals -> identical arity 2 + escapes false" do
    table = table_for(<<~RUBY)
      class Firewall
        def memo_version
          return @thing if defined?(@thing)
          @thing = fetch_thing
        rescue StandardError
          @thing = nil
        end

        def plain_version
          if ready?
            fetch_thing
          else
            nil
          end
        end
      end
    RUBY
    arities = R::ArityResolver.new(table).resolve
    expect(arities["Firewall#memo_version"]).to eq(2)
    expect(arities["Firewall#plain_version"]).to eq(2)
    expect(table.method_for("Firewall#memo_version").escapes).to be(false)
    expect(table.method_for("Firewall#plain_version").escapes).to be(false)
  end

  # --- D7 input gate: T2 trigger (contract widening moves arity) ----------------------

  it "T2 trigger: adding a distinguished false return widens arity 2 -> 3" do
    base = <<~RUBY
      class T2
        def check
          return nil unless present?
          compute_value
        end
      end
    RUBY
    widened = <<~RUBY
      class T2
        def check
          return nil unless present?
          return false if invalid?
          compute_value
        end
      end
    RUBY
    expect(R::ArityResolver.new(table_for(base)).resolve["T2#check"]).to eq(2)
    expect(R::ArityResolver.new(table_for(widened)).resolve["T2#check"]).to eq(3)
  end

  # --- D7 input gate: T3 trigger (escape flips, arity unchanged) ------------------------

  it "T3 trigger: adding yield flips escapes false -> true with arity unchanged" do
    closed = <<~RUBY
      class T3
        def each_item
          return nil if @items.empty?
          @items.first
        end
      end
    RUBY
    escaping = <<~RUBY
      class T3
        def each_item
          return nil if @items.empty?
          yield @items.first
          @items.first
        end
      end
    RUBY
    closed_table   = table_for(closed)
    escaping_table = table_for(escaping)
    expect(closed_table.method_for("T3#each_item").escapes).to be(false)
    expect(escaping_table.method_for("T3#each_item").escapes).to be(true)
    expect(R::ArityResolver.new(closed_table).resolve["T3#each_item"])
      .to eq(R::ArityResolver.new(escaping_table).resolve["T3#each_item"])
  end

  # --- D7 input gate: never-fabricate, end to end ----------------------------------------

  it "never-fabricate: an unresolved-tail def yields NO outcome_arity key downstream " \
     "(graph under either posture; descriptor null) + arity_unresolved counter = 1" do
    Dir.mktmpdir do |dir|
      abs = File.join(dir, "app", "models", "weird.rb")
      FileUtils.mkdir_p(File.dirname(abs))
      File.write(abs, <<~RUBY)
        class Weird
          def weird_tail
            alias a b
          end
        end
      RUBY

      config  = Archbuddy::Collect::Config.new(language: "ruby")
      adapter = Archbuddy::Collect::Registry.for("ruby").new(dir, config)
      result  = adapter.collect
      expect(result.diagnostics[:arity_unresolved]).to eq(1)

      anon = Archbuddy::Collect::Anonymizer.new(
        result, tool: "archbuddy test", adapter: "ruby"
      ).call
      opaque_id, desc = anon.id_map["ids"].find { |_i, d| d["symbol"] == "Weird#weird_tail" }
      node = anon.graph["nodes"].find { |n| n["id"] == opaque_id }

      # nil NEVER emits — the graph key is absent under BOTH engine postures
      expect(node).not_to have_key("outcome_arity")
      # the descriptor mirrors the honest null (present key, null value)
      expect(desc).to have_key("outcome_arity")
      expect(desc["outcome_arity"]).to be_nil
    end
  end
end
