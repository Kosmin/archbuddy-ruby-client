# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Archbuddy::Collect::Emitter do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }

  def build_anon
    adapter = Archbuddy::Collect::Registry.for("ruby").new(
      fixture_root, Archbuddy::Collect::Config.new(language: "ruby")
    )
    Archbuddy::Collect::Anonymizer.new(adapter.collect, tool: "t", adapter: "ruby").call
  end

  it "validates, then writes graph.yml + id-map.yml into a gitignored out dir" do
    Dir.mktmpdir do |project|
      # Mark the whole project tmp dir as a git repo with id-map.yml ignored so
      # the gitignore-before-secret guard passes for the secret write.
      File.write(File.join(project, ".gitignore"), "id-map.yml\n/out/\n")

      anon = build_anon
      out  = File.join(project, "out")
      emitter = described_class.new(out_dir: out, project_root: project)

      paths = emitter.emit(graph: anon.graph, id_map: anon.id_map)

      expect(File).to exist(paths[:graph])
      expect(File).to exist(paths[:id_map])

      loaded = ArchitectureAuditor::Contract::Serializer.load(paths[:graph])
      expect(ArchitectureAuditor::Contract::Validator.valid?(:graph, loaded)).to be(true)

      id_map = ArchitectureAuditor::Contract::Serializer.load(paths[:id_map])
      expect(id_map["ids"]).not_to be_empty
    end
  end

  it "refuses to write the secret when it is not gitignored (gitignore-before-secret)" do
    Dir.mktmpdir do |project|
      # No .gitignore entry for id-map.yml; force a non-matching filename so the
      # filename fallback also does not apply.
      anon = build_anon
      out  = File.join(project, "exports") # not /out/, no ignore rule
      emitter = described_class.new(out_dir: out, project_root: project)

      # Stub the filename check off by emitting under a custom name is not part
      # of the public API, so instead point at a project with no rule and a
      # non-git dir: filename fallback (id-map.yml) WOULD pass, so to prove the
      # guard we temporarily rename the constant expectation via a subclass.
      guarded = Class.new(Archbuddy::Collect::Emitter) do
        def filename_ignored?(_path) = false
      end.new(out_dir: out, project_root: project)

      expect {
        guarded.emit(graph: anon.graph, id_map: anon.id_map)
      }.to raise_error(Archbuddy::Collect::Emitter::SecretNotIgnoredError)

      # And the real emitter (filename fallback covers id-map.yml) succeeds.
      expect { emitter.emit(graph: anon.graph, id_map: anon.id_map) }.not_to raise_error
    end
  end
end

# v0.10 W1-A1: the emitted artifacts carry the ingress category on the SECRET
# side only (id-map descriptor); graph.yml stays a VALID document for the
# installed engine schema (a 1.2 node schema rejects unknown keys, so the
# graph stamp is gated until the engine declares the OPTIONAL field in 1.3).
RSpec.describe "Emitter entrypoint_kind carry (v0.10 W1-A1)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }

  def build_anon
    adapter = Archbuddy::Collect::Registry.for("ruby").new(
      fixture_root, Archbuddy::Collect::Config.new(language: "ruby")
    )
    Archbuddy::Collect::Anonymizer.new(adapter.collect, tool: "t", adapter: "ruby").call
  end

  it "writes a schema-VALID graph.yml and an id-map whose entrypoint descriptors carry the category" do
    Dir.mktmpdir do |project|
      File.write(File.join(project, ".gitignore"), "id-map.yml\n/out/\n")

      anon    = build_anon
      out     = File.join(project, "out")
      paths   = Archbuddy::Collect::Emitter.new(out_dir: out, project_root: project)
                                            .emit(graph: anon.graph, id_map: anon.id_map)

      loaded = ArchitectureAuditor::Contract::Serializer.load(paths[:graph])
      expect(ArchitectureAuditor::Contract::Validator.valid?(:graph, loaded)).to be(true)

      id_map = ArchitectureAuditor::Contract::Serializer.load(paths[:id_map])
      action = id_map["ids"].values.find { |d| d["symbol"] == "OrdersController#index" }
      expect(action["entrypoint_kind"]).to eq("controllers")

      non_ep = id_map["ids"].values.find { |d| d["symbol"] == "Billing::Invoice#total" }
      expect(non_ep).to have_key("entrypoint_kind")
      expect(non_ep["entrypoint_kind"]).to be_nil

      unless Archbuddy::Collect::Anonymizer.graph_schema_accepts_entrypoint_kind?
        loaded["nodes"].each { |n| expect(n).not_to have_key("entrypoint_kind") }
      end
    end
  end
end
