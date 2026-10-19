# frozen_string_literal: true

require "tmpdir"
require "yaml"

# THE ASSERTED-GRAPH OVERLAY (graph 1.8).
#
# The overlay exists because a static parser's blind spots are not uniformly
# distributed — `send`, metaprogramming, callback registration and DI wiring
# hide edges exactly where the architecture is most indirect. These examples
# pin the three properties that make an assertion safe to trust:
#
#   FUSES   — an assertion written in real names attaches to the node the
#             collector already emitted, via the shared mint, with no matching
#             pass. (If this broke, assertions would silently dangle.)
#   LABELS  — everything it adds carries provenance: "manual", so an assertion
#             can never be counted as an observation.
#   REFUSES — a symbol the collector never emitted is an ERROR unless declared,
#             because a typo would otherwise mint a plausible id, attach to
#             nothing, and add a phantom node nobody would notice.
RSpec.describe Archbuddy::Collect::ManualOverlay do
  include_context "engine contract" rescue nil

  let(:ids) { ArchitectureAuditor::Contract::Ids }

  # Two collected nodes, one collected edge between them.
  let(:caller_file) { "app/jobs/dispatcher.rb" }
  let(:caller_sym)  { "Dispatcher#perform" }
  let(:callee_file) { "app/services/builder.rb" }
  let(:callee_sym)  { "Builder#run" }
  let(:other_file)  { "app/services/mailer.rb" }
  let(:other_sym)   { "Mailer#deliver" }

  let(:caller_id) { ids.node_id(caller_file, caller_sym) }
  let(:callee_id) { ids.node_id(callee_file, callee_sym) }

  let(:base_graph) do
    {
      "schema_version" => ArchitectureAuditor::Contract::GRAPH_SCHEMA_VERSION,
      "generator" => { "tool" => "archbuddy test", "adapter" => "ruby", "capture" => "static" },
      "nodes" => [
        node(caller_id, "endpoint"),
        node(callee_id, "function")
      ],
      "edges" => [
        { "from" => caller_id, "to" => callee_id, "calls" => 2,
          "count" => nil, "self_time_ms" => nil }
      ],
      "entrypoints" => [caller_id]
    }
  end

  def node(id, kind)
    { "id" => id, "kind" => kind, "class_id" => nil, "loc" => nil,
      "self_time_ms" => nil, "total_time_ms" => nil, "count" => nil }
  end

  let(:id_map) do
    { "ids" => {
      caller_id => { "file" => caller_file, "symbol" => caller_sym, "kind" => "endpoint" },
      callee_id => { "file" => callee_file, "symbol" => callee_sym, "kind" => "function" }
    } }
  end

  let(:result) { Archbuddy::Collect::Anonymizer::Result.new(graph: base_graph, id_map: id_map) }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, ".archbuddy"))
      example.run
    end
  end

  def write_overlay(doc)
    File.write(File.join(@root, ".archbuddy", "manual-graph.yml"), YAML.dump(doc))
  end

  def apply
    overlay = described_class.new(project_root: @root)
    [overlay.apply(result), overlay]
  end

  describe "when no overlay exists" do
    it "returns the result UNTOUCHED — a repo without one pays nothing" do
      out, overlay = apply
      expect(overlay).not_to be_exist
      expect(out).to equal(result)
    end
  end

  describe "fusing an assertion onto collected nodes" do
    before do
      write_overlay(
        "schema_version" => "1.0",
        "edges" => [{
          "from" => { "file" => callee_file, "symbol" => callee_sym },
          "to"   => { "file" => other_file,  "symbol" => other_sym },
          "why"  => "dispatched via send(mailer_name)"
        }],
        "nodes" => [{
          "file" => other_file, "symbol" => other_sym, "kind" => "function",
          "why" => "registered by a metaprogrammed .register call"
        }]
      )
    end

    it "attaches the asserted edge to the COLLECTED node's existing id" do
      out, = apply
      added = out.graph["edges"].find { |e| e["provenance"] == "manual" }
      expect(added["from"]).to eq(callee_id)
    end

    it "stamps provenance on both the asserted edge and the asserted node" do
      out, = apply
      expect(out.graph["edges"].count { |e| e["provenance"] == "manual" }).to eq(1)
      expect(out.graph["nodes"].count { |n| n["provenance"] == "manual" }).to eq(1)
    end

    it "leaves every COLLECTED edge and node unmarked" do
      out, = apply
      collected = out.graph["edges"].reject { |e| e.key?("provenance") }
      expect(collected.length).to eq(1)
      expect(collected.first["calls"]).to eq(2)
    end

    it "records the asserted node in the SECRET id-map, never in graph.yml" do
      out, = apply
      other_id = ids.node_id(other_file, other_sym)
      expect(out.id_map["ids"][other_id]["symbol"]).to eq(other_sym)
      expect(YAML.dump(out.graph)).not_to include(other_sym)
      expect(YAML.dump(out.graph)).not_to include(other_file)
    end

    it "produces a graph that still VALIDATES against the 1.8 contract" do
      out, = apply
      expect(ArchitectureAuditor::Contract::Validator.valid?(:graph, out.graph)).to be(true)
    end

    it "reports what it added" do
      _, overlay = apply
      expect(overlay.report.edges_added).to eq(1)
      expect(overlay.report.nodes_added).to eq(1)
    end
  end

  describe "refusing to guess" do
    it "ERRORS on an edge naming a node the collector never emitted" do
      write_overlay(
        "schema_version" => "1.0",
        "edges" => [{
          "from" => { "file" => caller_file, "symbol" => "Dispatcher#perfrom" }, # typo
          "to"   => { "file" => callee_file, "symbol" => callee_sym },
          "why"  => "x"
        }]
      )
      expect { apply }.to raise_error(described_class::Error, /never emitted/)
    end

    it "ERRORS when an assertion carries no `why`" do
      write_overlay(
        "schema_version" => "1.0",
        "edges" => [{ "from" => { "file" => callee_file, "symbol" => callee_sym },
                      "to" => { "file" => caller_file, "symbol" => caller_sym } }]
      )
      expect { apply }.to raise_error(described_class::Error, /needs a `why`/)
    end

    it "ERRORS on an unsupported schema_version" do
      write_overlay("schema_version" => "9.9", "edges" => [])
      expect { apply }.to raise_error(described_class::Error, /unsupported schema_version/)
    end

    it "ERRORS on a node declared with an unknown kind" do
      write_overlay(
        "schema_version" => "1.0",
        "nodes" => [{ "file" => other_file, "symbol" => other_sym,
                      "kind" => "service", "why" => "x" }]
      )
      expect { apply }.to raise_error(described_class::Error, /must be one of/)
    end
  end

  describe "never downgrading an observation" do
    before do
      write_overlay(
        "schema_version" => "1.0",
        "edges" => [{
          "from" => { "file" => caller_file, "symbol" => caller_sym },
          "to"   => { "file" => callee_file, "symbol" => callee_sym },
          "why"  => "asserting something the parser already saw"
        }]
      )
    end

    it "leaves the OBSERVED edge intact and adds nothing" do
      out, overlay = apply
      expect(out.graph["edges"].length).to eq(1)
      expect(out.graph["edges"].first).not_to have_key("provenance")
      expect(out.graph["edges"].first["calls"]).to eq(2)
      expect(overlay.report.edges_redundant).to eq(1)
      expect(overlay.report.edges_added).to eq(0)
    end
  end

  describe "idempotency" do
    it "folds a repeated assertion into ONE edge" do
      assertion = {
        "from" => { "file" => callee_file, "symbol" => callee_sym },
        "to"   => { "file" => caller_file, "symbol" => caller_sym },
        "why"  => "callback re-entry"
      }
      # A DEEP copy, not `.dup`: a shallow copy shares the nested hashes and
      # Psych emits a YAML alias, which is not what a duplicated assertion looks
      # like in a real hand-written overlay (two independently typed entries).
      twin = Marshal.load(Marshal.dump(assertion))
      write_overlay("schema_version" => "1.0", "edges" => [assertion, twin])
      out, overlay = apply
      expect(overlay.report.edges_added).to eq(1)
      expect(out.graph["edges"].count { |e| e["provenance"] == "manual" }).to eq(1)
    end
  end
end
