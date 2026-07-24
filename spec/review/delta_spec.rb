# frozen_string_literal: true

require "archbuddy/review"
require "archbuddy/review/delta"

# v0.15 P2-T4: Review::Delta — node-level classification + L6 net rollup +
# scopes ([S] rows) and the ep-level surfaces: ep_entries (U_metric, Q2),
# review_surface (Q3), disclosures (Q2), re-keyed ep_deltas (Q7). The Q5
# canon rides the P2-T4-authored twin fixtures (§5-C28).
RSpec.describe Archbuddy::Review::Delta do
  FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)
  REDEEM_KEY = ["app/api/api/v1/redeem_templates.rb", "Api::V1::RedeemTemplates#PATCH[0]"].freeze

  def node(file:, symbol:, branches: 1, decisions: 0, entrypoint: false, escapes: false,
           outcome_arity: 1, toll_booth: nil, kind: "function")
    Archbuddy::Review::Vintage::Node.new(
      file: file, symbol: symbol, kind: kind, klass: nil,
      branches: branches, decisions: decisions, entrypoint: entrypoint,
      entrypoint_kind: entrypoint ? "grape" : nil, escapes: escapes,
      outcome_arity: outcome_arity, toll_booth: toll_booth, quadrant: nil,
      leverage: nil, collapse: nil, serializer_version: 5,
      keys_present: %w[branches symbol escapes outcome_arity toll_booth]
    )
  end

  def vintage(nodes, edges = [])
    Archbuddy::Review::Vintage.new(nodes: nodes, edges: edges)
  end

  def read(name)
    Archbuddy::Review::FragmentWalk.read(File.join(FIXTURES, name))
  end

  def twin_2083
    described_class.new(base: read("twin_2083_base"), head: read("twin_2083_head"))
  end

  def twin_2146
    described_class.new(base: read("twin_2146_base"), head: read("twin_2146_head"))
  end

  describe "the #2083 twin — node rows ([S])" do
    it "classifies GROWN +3.0 exactly and NEW +0.0, net 3.000" do
      delta = twin_2083
      grown = delta.entries.find { |e| e.classification == :grown }
      expect(grown.symbol).to eq("Api::V1::RedeemTemplates#PATCH[0]")
      expect(grown.delta_log2).to eq(3.0)
      expect(grown.base_branches).to eq(8192)
      expect(grown.head_branches).to eq(65_536)

      born = delta.entries.find { |e| e.classification == :new }
      expect(born.symbol).to eq("Program::Redeem::Template#bonus_points?")
      expect(born.delta_log2).to eq(0.0)

      expect(delta.net_log2.round(3)).to eq(3.000)
      expect(delta.counts).to eq(new: 1, grown: 1, shrunk: 0, removed: 0)
    end
  end

  describe "the #2083 twin — ep surfaces (Q5 canon)" do
    let(:delta) { twin_2083 }

    it "materializes EXACTLY one :matched U_metric entry with the canon vectors" do
      expect(delta.ep_entries.size).to eq(1)
      entry = delta.ep_entries.first
      expect([entry.file, entry.ep_symbol]).to eq(REDEEM_KEY)
      expect(entry.classification).to eq(:matched)

      expect(entry.delta[:branching_log2]).to eq(3.0)
      expect(entry.delta[:mass]).to eq(10)
      expect(entry.delta[:reach]).to eq(0)
      expect(entry.delta[:files]).to eq(0)
      expect(entry.delta[:depth]).to eq(0)
      expect(entry.delta[:dividend_log2]).to be_within(1e-9).of(3.0)

      expect(entry.base.branching_log2).to eq(13.0)
      expect(entry.base.mass).to eq(73)
      expect(entry.base.reach).to eq(2)
      expect(entry.base.files).to eq(1)
      expect(entry.base.depth).to eq(2)
      expect(entry.base.dividend.round(6)).to eq(8192.0)

      expect(entry.head.branching_log2).to eq(16.0)
      expect(entry.head.mass).to eq(83)
      expect(entry.head.reach).to eq(2)
      expect(entry.head.files).to eq(1)
      expect(entry.head.depth).to eq(2)
      expect(entry.head.dividend.round(6)).to eq(65_536.0)
    end

    it "lists ONE contributor line (zero node noise)" do
      entry = delta.ep_entries.first
      expect(entry.contributors.size).to eq(1)
      contributor = entry.contributors.first
      expect(contributor[:symbol]).to eq("Api::V1::RedeemTemplates#PATCH[0]")
      expect(contributor[:delta_log2]).to eq(3.0)
      expect(contributor[:value_raw]).to eq(65_536)
      expect(contributor[:coupling_flip]).to be(false)
      expect(entry.contributors_omitted).to eq(0)
    end

    it "computes review_surface {union: 1, sum: 1} + the bonus_points? disclosure" do
      rs = delta.review_surface
      expect(rs[:union]).to eq(1)
      expect(rs[:sum]).to eq(1)
      expect(rs[:eps].first[:ep_symbol]).to eq("Api::V1::RedeemTemplates#PATCH[0]")
      expect(rs[:unreachable_touched][:count]).to eq(1)
      expect(rs[:unreachable_touched][:nodes])
        .to eq([{ file: "app/models/program/redeem/template.rb",
                  symbol: "Program::Redeem::Template#bonus_points?" }])
    end

    it "discloses the orphan-touched template.rb file" do
      expect(delta.disclosures[:orphan_touched_files])
        .to eq(["app/models/program/redeem/template.rb"])
      expect(delta.disclosures[:offsetting_zero_count]).to eq(0)
    end
  end

  describe "the #2146 twin — 2 NEW eps (Q5 canon; V15-F2 non-empty base)" do
    let(:delta) { twin_2146 }

    it "keeps the base evaluable and net +1.000 with nodes_new == 2" do
      expect(delta.base.nodes.size).to eq(1) # V15-F2: minimal NON-empty base
      expect(delta.base.edges?).to be(true)
      expect(delta.net_log2.round(3)).to eq(1.000)
      expect(delta.counts[:new]).to eq(2)
    end

    it "materializes 2 :new entries with the canon head vectors and nil bases" do
      expect(delta.ep_entries.size).to eq(2)
      get_entry, patch_entry = delta.ep_entries.sort_by(&:ep_symbol)

      expect(get_entry.ep_symbol).to eq("Api::V1::SegmentActivationPreferences#GET[0]")
      expect(get_entry.classification).to eq(:new)
      expect(get_entry.base).to be_nil # absent, NEVER zeroed
      expect(get_entry.head.branching_log2).to eq(0.0)
      expect(get_entry.head.mass).to eq(7)
      expect(get_entry.head.reach).to eq(1)
      expect(get_entry.head.files).to eq(1)
      expect(get_entry.head.depth).to eq(1)
      expect(get_entry.head.dividend.round(6)).to eq(1.0)

      expect(patch_entry.ep_symbol).to eq("Api::V1::SegmentActivationPreferences#PATCH[0]")
      expect(patch_entry.base).to be_nil
      expect(patch_entry.head.branching_log2).to eq(1.0)
      expect(patch_entry.head.mass).to eq(22)
      expect(patch_entry.head.reach).to eq(1)
      expect(patch_entry.head.files).to eq(1)
      expect(patch_entry.head.depth).to eq(1)
      expect(patch_entry.head.dividend.round(6)).to eq(2.0)
    end

    it "computes review_surface {union: 2, sum: 2} (NEW eps self-announce)" do
      expect(delta.review_surface[:union]).to eq(2)
      expect(delta.review_surface[:sum]).to eq(2)
      expect(delta.review_surface[:unreachable_touched][:count]).to eq(0)
    end
  end

  describe "ep rename-neutrality (PR #154 shape, Q7)" do
    it "yields pairwise-identical vectors and Σ Δbranching == 0.000000 EXACTLY" do
      files = "app/api/legal.rb"
      old_eps = (0..5).map do |i|
        node(file: files, symbol: "LegalDoc#m#{i}[0]", branches: 2**i, entrypoint: true,
             kind: "endpoint")
      end
      new_eps = (0..5).map do |i|
        node(file: files, symbol: "LegalDocApi#m#{i}[0]", branches: 2**i, entrypoint: true,
             kind: "endpoint")
      end
      delta = described_class.new(base: vintage(old_eps, []), head: vintage(new_eps, []))

      expect(delta.ep_entries.size).to eq(12)
      removed = delta.ep_entries.select { |e| e.classification == :removed }
      added = delta.ep_entries.select { |e| e.classification == :new }
      expect(removed.size).to eq(6)
      expect(added.size).to eq(6)

      removed_vectors = removed.map { |e| e.base.branching_log2 }.sort
      added_vectors = added.map { |e| e.head.branching_log2 }.sort
      expect(added_vectors).to eq(removed_vectors) # pairwise-identical

      signed = delta.ep_entries.sum do |e|
        e.classification == :removed ? -e.base.branching_log2 : e.head.branching_log2
      end
      expect(signed).to eq(0.0) # EXACT IEEE cancellation

      expect(delta.ep_deltas.values.sum { |m| m[:delta] }).to eq(0.0) # ratchet-neutral
      expect(delta.net_log2).to eq(0.0)
    end
  end

  describe "node-level [S] fixtures" do
    it "rename cancels EXACTLY and stays ratchet-neutral" do
      old_nodes = (0..5).map { |i| node(file: "a.rb", symbol: "LegalDoc#m#{i}", branches: 3**i) }
      renamed = (0..5).map { |i| node(file: "a.rb", symbol: "LegalDocApi#m#{i}", branches: 3**i) }
      delta = described_class.new(base: vintage(old_nodes), head: vintage(renamed))
      expect(delta.counts).to eq(new: 6, grown: 0, shrunk: 0, removed: 6)
      expect(delta.net_log2).to eq(0.000)
      expect(delta.scope_net(paths: ["**/*"])).to eq(0.000)
    end

    it "annotates MOVED entries (math stays remove+add)" do
      base_nodes = [node(file: "a/x.rb", symbol: "X#run", branches: 8, decisions: 3)]
      head_nodes = [node(file: "b/x.rb", symbol: "X#run", branches: 8, decisions: 3)]
      delta = described_class.new(base: vintage(base_nodes), head: vintage(head_nodes))

      expect(delta.scope_net(paths: ["a/**/*"])).to be < 0
      expect(delta.scope_net(paths: ["b/**/*"])).to be > 0
      expect(delta.net_log2).to eq(0.0)

      removed = delta.entries.find { |e| e.classification == :removed }
      added = delta.entries.find { |e| e.classification == :new }
      expect(removed.moved_to).to eq("b/x.rb")
      expect(added.moved_from).to eq("a/x.rb")
    end

    it "carries escape transitions as CHANGED_ATTRS (delta 0.0, outside counts)" do
      base_nodes = [node(file: "a.rb", symbol: "A#x", branches: 4, escapes: false)]
      head_nodes = [node(file: "a.rb", symbol: "A#x", branches: 4, escapes: true)]
      delta = described_class.new(base: vintage(base_nodes), head: vintage(head_nodes))
      expect(delta.entries.size).to eq(1)
      expect(delta.entries.first.classification).to eq(:changed_attrs)
      expect(delta.entries.first.delta_log2).to eq(0.0)
      expect(delta.counts.values.sum).to eq(0)
    end
  end

  describe "ep_deltas (the re-keyed ratchet seam, Q7/R43)" do
    it "keys (file, ep_symbol), includes unchanged eps at 0.0, NEW/REMOVED in full" do
      base_v = vintage(
        [node(file: "a.rb", symbol: "Kept#GET[0]", branches: 4, entrypoint: true, kind: "endpoint"),
         node(file: "a.rb", symbol: "Gone#GET[0]", branches: 8, entrypoint: true, kind: "endpoint")]
      )
      head_v = vintage(
        [node(file: "a.rb", symbol: "Kept#GET[0]", branches: 4, entrypoint: true, kind: "endpoint"),
         node(file: "a.rb", symbol: "Born#GET[0]", branches: 16, entrypoint: true, kind: "endpoint")]
      )
      deltas = described_class.new(base: base_v, head: head_v).ep_deltas

      expect(deltas[["a.rb", "Kept#GET[0]"]]).to include(classification: :matched, delta: 0.0)
      expect(deltas[["a.rb", "Gone#GET[0]"]]).to include(classification: :removed, delta: -3.0)
      expect(deltas[["a.rb", "Born#GET[0]"]]).to include(classification: :new, delta: 4.0)
    end
  end

  describe "U_metric quiet + disclosures" do
    it "comment-only pair: ep_entries [], union 0, offsetting_zero 0" do
      nodes = [node(file: "a.rb", symbol: "Ep#GET[0]", branches: 4, entrypoint: true, kind: "endpoint")]
      delta = described_class.new(base: vintage(nodes), head: vintage(nodes))
      expect(delta.ep_entries).to eq([])
      expect(delta.review_surface[:union]).to eq(0)
      expect(delta.disclosures[:offsetting_zero_count]).to eq(0)
    end

    it "offsetting-zero cone: ep NOT in U_metric, count == 1" do
      edges = [{ from: "Ep#GET[0]", to: "n1", calls: 1 }, { from: "Ep#GET[0]", to: "n2", calls: 1 }]
      base_v = vintage(
        [node(file: "a.rb", symbol: "Ep#GET[0]", branches: 2, entrypoint: true, kind: "endpoint"),
         node(file: "a.rb", symbol: "n1", branches: 4), node(file: "a.rb", symbol: "n2", branches: 2)],
        edges
      )
      head_v = vintage(
        [node(file: "a.rb", symbol: "Ep#GET[0]", branches: 2, entrypoint: true, kind: "endpoint"),
         node(file: "a.rb", symbol: "n1", branches: 2), node(file: "a.rb", symbol: "n2", branches: 4)],
        edges
      )
      delta = described_class.new(base: base_v, head: head_v)
      expect(delta.ep_entries).to eq([])
      expect(delta.disclosures[:offsetting_zero_count]).to eq(1)
    end

    it "tags coupling-flip contributors (payload unchanged, edge set changed)" do
      base_v = vintage(
        [node(file: "a.rb", symbol: "Ep#GET[0]", branches: 4, entrypoint: true, kind: "endpoint"),
         node(file: "a.rb", symbol: "helper", branches: 2)],
        [{ from: "Ep#GET[0]", to: "helper", calls: 1 }, { from: "helper", to: "Ext.x", calls: 1 }]
      )
      head_v = vintage(
        [node(file: "a.rb", symbol: "Ep#GET[0]", branches: 4, entrypoint: true, kind: "endpoint"),
         node(file: "a.rb", symbol: "helper", branches: 2)],
        [{ from: "Ep#GET[0]", to: "helper", calls: 1 }, { from: "helper", to: "Ext.y", calls: 2 }]
      )
      delta = described_class.new(base: base_v, head: head_v)
      entry = delta.ep_entries.first
      expect(entry).not_to be_nil # mass moved 2 → 3
      flip = entry.contributors.find { |c| c[:coupling_flip] }
      expect(flip).not_to be_nil
      expect(flip[:symbol]).to eq("helper")
      expect(flip[:delta_log2]).to be_nil
    end
  end

  describe "degenerate / empty-input behavior" do
    it "identical vintages → empty first-class delta" do
      nodes = [node(file: "a.rb", symbol: "A#x", branches: 4)]
      delta = described_class.new(base: vintage(nodes), head: vintage(nodes))
      expect(delta.entries).to eq([])
      expect(delta.net_log2).to eq(0.0)
      expect(delta.counts.values.sum).to eq(0)
    end

    it "both empty → same" do
      delta = described_class.new(base: vintage([]), head: vintage([]))
      expect(delta.entries).to eq([])
      expect(delta.net_log2).to eq(0.0)
      expect(delta.ep_entries).to eq([])
      expect(delta.ep_deltas).to eq({})
    end

    it "empty base × non-empty head → every head node NEW, full-positive net" do
      head_nodes = [node(file: "a.rb", symbol: "A#x", branches: 8),
                    node(file: "a.rb", symbol: "A#y", branches: 4)]
      delta = described_class.new(base: vintage([]), head: vintage(head_nodes))
      expect(delta.counts[:new]).to eq(2)
      expect(delta.net_log2).to eq(Math.log2(8) + Math.log2(4))
    end

    it "no-match glob → 0.0 AND scope_match? false (the no_match pair)" do
      nodes = [node(file: "a.rb", symbol: "A#x", branches: 4)]
      delta = described_class.new(base: vintage([]), head: vintage(nodes))
      expect(delta.scope_net(paths: ["vendor/**/*"])).to eq(0.0)
      expect(delta.scope_match?(paths: ["vendor/**/*"])).to be(false)
      expect(delta.scope_match?(paths: ["a.rb"])).to be(true)
    end

    it "excludes corrupt files from every sum, surfacing them" do
      corrupt_base = Archbuddy::Review::Vintage.new(
        nodes: [node(file: "bad.rb", symbol: "B#x", branches: 64)],
        edges: [], corrupt_files: ["bad.rb"]
      )
      head_v = vintage([node(file: "bad.rb", symbol: "B#x", branches: 128)])
      delta = described_class.new(base: corrupt_base, head: head_v)
      expect(delta.excluded_files).to eq(["bad.rb"])
      expect(delta.entries).to eq([]) # never silently classified
      expect(delta.net_log2).to eq(0.0)
    end

    it "zero eps on both sides → honest empty ep surfaces + all-unreachable disclosure" do
      base_v = vintage([node(file: "a.rb", symbol: "A#x", branches: 4)])
      head_v = vintage([node(file: "a.rb", symbol: "A#x", branches: 8)])
      delta = described_class.new(base: base_v, head: head_v)
      expect(delta.ep_entries).to eq([])
      expect(delta.ep_deltas).to eq({})
      rs = delta.review_surface
      expect(rs[:union]).to eq(0)
      expect(rs[:sum]).to eq(0)
      expect(rs[:eps]).to eq([])
      expect(rs[:unreachable_touched][:count]).to eq(1) # never a safety claim
    end
  end
end
