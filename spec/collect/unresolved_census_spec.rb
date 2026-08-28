# frozen_string_literal: true

require "spec_helper"
require "set"
require "archbuddy/collect/adapters/ruby/unresolved_census"

RSpec.describe Archbuddy::Collect::Adapters::Ruby::UnresolvedCensus do
  Entry = Struct.new(:fq_symbol, :name, :branches, keyword_init: true)

  def leafmap(methods, degrees)
    described_class.leaf_by_name(methods, ->(fq) { degrees.fetch(fq, 0) })
  end

  describe ".leaf_by_name" do
    it "calls a method with no successors and no branching a LEAF" do
      m = [Entry.new(fq_symbol: "A#name", name: "name", branches: 1)]
      expect(leafmap(m, {})).to eq("name" => true)
    end

    it "does NOT call a method with successors a leaf, however simple its body" do
      m = [Entry.new(fq_symbol: "A#call", name: "call", branches: 1)]
      expect(leafmap(m, "A#call" => 3)).to eq("call" => false)
    end

    it "does NOT call a BRANCHING method a leaf, however few successors" do
      m = [Entry.new(fq_symbol: "A#status", name: "status", branches: 8)]
      expect(leafmap(m, {})).to eq("status" => false)
    end

    it "requires EVERY method of a shared name to be a leaf before saying leaf" do
      m = [Entry.new(fq_symbol: "A#amount", name: "amount", branches: 1),
           Entry.new(fq_symbol: "B#amount", name: "amount", branches: 6)]
      expect(leafmap(m, {})).to eq("amount" => false)
    end
  end

  describe ".classify" do
    it "counts a name with NO application definition as cost-1 — the strongest case" do
      # A gem call, a schema attribute, any data access: nothing in this
      # codebase defines it, so there was never a subtree to miss.
      r = described_class.classify(names: %w[nickname save], leaf_by_name: {})
      expect([r.total, r.cost_1, r.complex]).to eq([2, 2, 0])
    end

    it "counts a name whose every definition is a leaf as cost-1" do
      r = described_class.classify(names: %w[name], leaf_by_name: { "name" => true })
      expect(r.cost_1).to eq(1)
    end

    it "counts a name with a real subtree as potentially complex" do
      r = described_class.classify(names: %w[merge_variables], leaf_by_name: { "merge_variables" => false })
      expect([r.cost_1, r.complex]).to eq([0, 1])
    end

    it "reports a RANGE: a gem-side namesake stays in the loose bound, out of the tight one" do
      # `id` names an application method with a body AND hundreds of library
      # ones, so matching it by name is mostly coincidence. `merge_variables`
      # exists only here, so the match is probably real.
      r = described_class.classify(
        names: %w[id merge_variables],
        leaf_by_name: { "id" => false, "merge_variables" => false },
        outside_names: Set.new(%w[id])
      )
      expect([r.complex, r.complex_exclusive]).to eq([2, 1])
    end

    it "widens rather than narrows when reflection never ran" do
      # No outside_names means nothing can be excluded, so the tight bound
      # collapses ONTO the loose one — more uncertainty reported, never less.
      r = described_class.classify(names: %w[id], leaf_by_name: { "id" => false })
      expect(r.complex_exclusive).to eq(r.complex)
    end

    it "names the worst offenders from the TIGHT set, which is the actionable one" do
      r = described_class.classify(
        names: %w[amount amount amount id id merge_variables],
        leaf_by_name: { "amount" => false, "id" => false, "merge_variables" => false },
        outside_names: Set.new(%w[id])
      )
      expect(r.top_names).to eq("amount" => 3, "merge_variables" => 1)
    end

    it "counts SITES, not distinct names — the same call in a loop is two sites" do
      r = described_class.classify(names: %w[amount amount], leaf_by_name: { "amount" => false })
      expect([r.total, r.complex]).to eq([2, 2])
    end

    it "is 100% cost-1 when nothing resolvable was missed" do
      r = described_class.classify(names: %w[a b c], leaf_by_name: {})
      expect(r.cost_1_share).to eq(1.0)
    end

    it "survives an empty run without dividing by zero" do
      r = described_class.classify(names: [], leaf_by_name: {})
      expect([r.total, r.cost_1_share]).to eq([0, 0.0])
    end
  end
end
