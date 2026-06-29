# frozen_string_literal: true

require "tmpdir"

# END-TO-END Grape node-discovery + handler-context (W2 — the marquee 277→0
# fix in miniature). Feeds inline Grape source through the REAL adapter and
# Anonymizer, then asserts: Grape endpoint blocks become kind:"endpoint" nodes,
# they are entrypoints, and their handler-body calls emit REAL outgoing edges
# (the 0→N guard). Proves Pass-1 mint FQ == Pass-2 push FQ (F5) because edges
# only land when the from-node key resolves.
RSpec.describe "Grape endpoint discovery + handler context (W2 e2e)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  # A small but representative Grape API: helper methods (resolvable self-calls),
  # an AR model (db_op), and four endpoints whose bodies fan out. Without the
  # handler-context fix these blocks emit ZERO edges; with it they resolve.
  SOURCE = <<~RUBY
    class User < ApplicationRecord
    end

    class Api < Grape::API
      helpers do
        def authorize!
          1
        end

        def serialize(x)
          x
        end
      end

      get "/users" do
        authorize!
        User.all
        serialize(:users)
      end

      post "/users" do
        authorize!
        User.create
      end

      get "/health" do
        authorize!
      end

      delete "/users/:id" do
        serialize(:gone)
      end
    end
  RUBY

  def in_grape_repo
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "api.rb"), SOURCE)
      yield dir
    end
  end

  def collect(dir)
    Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
  end

  def anonymize(dir)
    Archbuddy::Collect::Anonymizer.new(
      collect(dir), tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  it "mints kind:\"endpoint\" nodes for every Grape verb-block" do
    in_grape_repo do |dir|
      result = anonymize(dir)
      endpoint_descs = result.id_map["ids"].select { |_id, d| d["kind"] == "endpoint" }
      symbols = endpoint_descs.map { |_id, d| d["symbol"] }.sort
      expect(symbols).to eq(
        ["Api#DELETE[0]", "Api#GET[0]", "Api#GET[1]", "Api#POST[0]"]
      )

      graph_kinds = result.graph["nodes"].map { |n| n["kind"] }
      expect(graph_kinds.count("endpoint")).to eq(4)
    end
  end

  it "registers each Grape endpoint as a graph entrypoint" do
    in_grape_repo do |dir|
      result = anonymize(dir)
      endpoint_ids = result.id_map["ids"]
                           .select { |_id, d| d["kind"] == "endpoint" }
                           .map { |id, _d| id }
      expect(endpoint_ids).not_to be_empty
      expect(result.graph["entrypoints"]).to include(*endpoint_ids)
    end
  end

  # THE 0→N GUARD: the whole point of W2. Endpoint handler bodies used to emit
  # ZERO edges; now they must emit several (>= 3 endpoint-origin edges here).
  it "emits >= 3 outgoing edges ORIGINATING from Grape endpoint nodes (was 0)" do
    in_grape_repo do |dir|
      result = anonymize(dir)
      endpoint_ids = result.id_map["ids"]
                           .select { |_id, d| d["kind"] == "endpoint" }
                           .map { |id, _d| id }
                           .to_set

      endpoint_edges = result.graph["edges"].select { |e| endpoint_ids.include?(e["from"]) }
      expect(endpoint_edges.length).to be >= 3
    end
  end

  it "resolves a handler self-call to a helper method (real edge, F5 parity)" do
    in_grape_repo do |dir|
      result = anonymize(dir)
      id_for = ->(sym) { result.id_map["ids"].find { |_i, d| d["symbol"] == sym }&.first }

      get_users_id  = id_for.call("Api#GET[0]")
      authorize_id  = id_for.call("Api#authorize!")
      expect(get_users_id).not_to be_nil
      expect(authorize_id).not_to be_nil

      edge = result.graph["edges"].find { |e| e["from"] == get_users_id && e["to"] == authorize_id }
      expect(edge).not_to be_nil, "expected GET[0] handler -> Api#authorize! edge"
      expect(edge["calls"]).to be >= 1
    end
  end

  it "produces a graph that validates against the engine's graph schema" do
    in_grape_repo do |dir|
      graph = anonymize(dir).graph
      expect {
        ArchitectureAuditor::Contract::Validator.validate!(:graph, graph)
      }.not_to raise_error
    end
  end

  it "emits 0 endpoint-origin edges for an empty-block endpoint (never fabricates)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "empty_api.rb"), <<~RUBY)
        class EmptyApi < Grape::API
          get "/nothing" do
          end
        end
      RUBY
      result = anonymize(dir)
      endpoint_ids = result.id_map["ids"]
                           .select { |_id, d| d["kind"] == "endpoint" }
                           .map { |id, _d| id }
                           .to_set
      expect(endpoint_ids.size).to eq(1)
      endpoint_edges = result.graph["edges"].select { |e| endpoint_ids.include?(e["from"]) }
      expect(endpoint_edges).to be_empty
    end
  end
end

# Grape MOUNT-tree probe (W3 — CONSUMES the seam). A `mount Const` provably
# composes the mounted Grape::API. When it appears in a context with a real
# caller (an endpoint handler body / a helper method) and the mounted const is
# a KNOWN Grape::API with at least one minted endpoint node, the probe emits a
# single edge to that API's representative (first-declared) endpoint node.
# Otherwise it DECLINES (unknown/non-Grape const, dynamic mount, empty API) so
# the call falls through to <external>. Never fabricates a class-target edge.
RSpec.describe "Grape mount-tree probe (W3)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def in_repo(source)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "api.rb"), source)
      yield dir
    end
  end

  def anonymize(dir)
    Archbuddy::Collect::Anonymizer.new(
      Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect,
      tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  def id_for(result, sym)
    result.id_map["ids"].find { |_i, d| d["symbol"] == sym }&.first
  end

  def edge?(result, from_sym, to_sym)
    from_id = id_for(result, from_sym)
    to_id   = id_for(result, to_sym)
    return false if from_id.nil? || to_id.nil?

    result.graph["edges"].any? { |e| e["from"] == from_id && e["to"] == to_id }
  end

  it "resolves a mount of a known Grape::API to its representative endpoint node" do
    # The mount sits inside an endpoint handler body so it has a real caller FQ.
    source = <<~RUBY
      class SubApi < Grape::API
        get "/things" do
          1
        end
      end

      class Api < Grape::API
        get "/compose" do
          mount SubApi
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = anonymize(dir)
      # SubApi's first endpoint (GET ordinal 0) is the representative node.
      expect(id_for(result, "SubApi#GET[0]")).not_to be_nil
      expect(edge?(result, "Api#GET[0]", "SubApi#GET[0]")).to be(true)
    end
  end

  it "tallies the mount edge under diagnostics[:probe_edges][:grape]" do
    source = <<~RUBY
      class SubApi < Grape::API
        get "/things" do
          1
        end
      end

      class Api < Grape::API
        get "/compose" do
          mount SubApi
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
      expect(result.diagnostics[:probe_edges][:grape]).to be >= 1
    end
  end

  it "declines a mount of an UNKNOWN constant (-> no probe edge)" do
    source = <<~RUBY
      class Api < Grape::API
        get "/compose" do
          mount NotDefinedAnywhere
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = anonymize(dir)
      expect(id_for(result, "NotDefinedAnywhere#GET[0]")).to be_nil
      # The mount site resolves to <external>, not a fabricated edge.
      go_id  = id_for(result, "Api#GET[0]")
      ext_id = id_for(result, "<external>")
      expect(result.graph["edges"].any? { |e| e["from"] == go_id && e["to"] == ext_id }).to be(true)
    end
  end

  it "declines a mount of a NON-Grape constant" do
    source = <<~RUBY
      class PlainThing
        def go
          1
        end
      end

      class Api < Grape::API
        get "/compose" do
          mount PlainThing
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
      expect(result.diagnostics[:probe_edges].fetch(:grape, 0)).to eq(0)
    end
  end

  it "declines a DYNAMIC mount (non-constant argument)" do
    source = <<~RUBY
      class Api < Grape::API
        get "/compose" do
          mount build_api
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
      expect(result.diagnostics[:probe_edges].fetch(:grape, 0)).to eq(0)
    end
  end

  it "declines a mount of a Grape::API with ZERO endpoint nodes (no fabricated edge)" do
    source = <<~RUBY
      class EmptySub < Grape::API
      end

      class Api < Grape::API
        get "/compose" do
          mount EmptySub
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
      expect(result.diagnostics[:probe_edges].fetch(:grape, 0)).to eq(0)
    end
  end
end
