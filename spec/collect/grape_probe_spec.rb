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
