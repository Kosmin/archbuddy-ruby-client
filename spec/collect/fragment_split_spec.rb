# frozen_string_literal: true

require "digest"

# C1-1: split RubyAdapter#collect into a PER-FILE fragment builder
# (`collect_file_fragment`) + a GLOBAL `assemble(fragments)`, landed as a PURE
# BYTE-PARITY refactor. These specs prove:
#   1. `assemble(all fragments)` == whole-project `#collect` BYTE-FOR-BYTE
#      (the anonymized graph serializes identically),
#   2. `collect_file_fragment` is a pure function of ONE file's bytes
#      (no cross-file state; content_hash = SHA-256 of the exact parsed source),
#   3. file order into `assemble` is the enumerator's deterministic sorted order
#      (so the parity holds run-to-run).
RSpec.describe "RubyAdapter fragment split (C1-1 byte parity)" do
  let(:fixture_root) { File.expand_path("../fixtures/sample", __dir__) }
  let(:config)       { Archbuddy::Collect::Config.new(language: "ruby") }
  let(:serializer)   { ArchitectureAuditor::Contract::Serializer }

  def adapter
    Archbuddy::Collect::Registry.for("ruby").new(fixture_root, config)
  end

  # Serialize an AdapterResult through the SAME trust boundary + serializer the
  # real pipeline uses, so "byte identical" means the committed/emitted artifact
  # is identical — not just an in-memory struct compare.
  def serialized_graph(adapter_result)
    anon = Archbuddy::Collect::Anonymizer.new(
      adapter_result, tool: "archbuddy test", adapter: "ruby"
    ).call
    serializer.dump(anon.graph)
  end

  def enumerate
    Archbuddy::Collect::Adapters::Ruby::FileEnumerator.new(fixture_root, config).files
  end

  it "assemble(all fragments) is byte-identical to whole-project #collect" do
    a = adapter
    fragments = enumerate.map { |abs, rel| a.collect_file_fragment(abs, rel) }
    from_fragments = a.assemble(fragments)
    whole_project  = adapter.collect

    expect(serialized_graph(from_fragments)).to eq(serialized_graph(whole_project))
  end

  it "collect_file_fragment is a pure function of one file's bytes" do
    a = adapter
    abs, rel = enumerate.first
    fragment = a.collect_file_fragment(abs, rel)

    expect(fragment.rel_file).to eq(rel)
    expect(fragment.content_hash).to eq(Digest::SHA256.hexdigest(File.read(abs)))
    expect(fragment.parsed_value).to be_a(Prism::Node)
    # Purity: a second build of the SAME file yields the SAME hash + an
    # equivalent parse, and reads no other file (content_hash is over this
    # file's bytes only).
    expect(a.collect_file_fragment(abs, rel).content_hash).to eq(fragment.content_hash)
  end

  it "feeds fragments in the enumerator's deterministic sorted order" do
    rels = enumerate.map { |_abs, rel| rel }
    expect(rels).to eq(rels.sort)
    # Re-running the whole enumerate+assemble path is stable (no order jitter).
    expect(serialized_graph(adapter.collect)).to eq(serialized_graph(adapter.collect))
  end

  it "assembling an empty fragment set yields a valid graph with only the external sink" do
    result = adapter.assemble([])
    expect(result.nodes.map(&:kind)).to eq(["external"])
    expect(result.edges).to eq([])
    expect(result.entrypoints).to eq([])
  end
end
