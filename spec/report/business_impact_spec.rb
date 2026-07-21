# frozen_string_literal: true

require "archbuddy/report"
require "archbuddy/report/formatter"
require "archbuddy/report/business_impact"

# v0.11 W-C (L6/L17): the ONE shared Business Impact presenter — five verbatim
# business questions + the ungraded branching footer, every number a VERBATIM
# engine figure, omission-not-fabrication throughout. These specs pin the
# EXACT copy strings (byte-level) and the nil-tolerance rules both formatters
# rely on.
RSpec.describe Archbuddy::Report::BusinessImpact do
  BI = described_class
  RS = Archbuddy::Report::Scores

  def context_with(**fields)
    Archbuddy::Report::Formatter::RenderContext.new(
      ranked: [], class_rollups: [], generator: {}, **fields
    )
  end

  def dim(key, score:, grade:, median: nil, median_grade: nil, capped_fraction: nil)
    RS::DimensionScore.new(
      key: key, label: key, question: "", score: score, grade: grade,
      hotspots: [], median: median, median_grade: median_grade,
      capped_fraction: capped_fraction
    )
  end

  # The MEASURED plan numbers (L14/L15/L16 — the I8 worked examples).
  let(:blast) do
    RS::BlastRadius.new(
      max: 1569, p90: 3.0, median: 1.0, mean: 121.38,
      reached_nodes: 5506, total_nodes: 16_173, total_entrypoints: 1611,
      pct_use_cases_hit_by_worst: 0.9739,
      worst: [
        RS::BlastRadius::Worst.new(symbol: "Router#dispatch", use_cases_affected: 1569, added_coupling: 7.5),
        RS::BlastRadius::Worst.new(symbol: "App#boot", use_cases_affected: 900, added_coupling: nil)
      ]
    )
  end
  let(:fwd_depth) { RS::DepthStats.new(mean: 2.83, median: 2.0, count: 1611) }
  let(:rev_depth) { RS::DepthStats.new(mean: 3.42, median: 3.0, count: 5506) }
  let(:branching) { RS::BranchingFactor.new(mean: 2649.6, median: 2.416, count: 1611) }
  let(:reverse_dim) do
    dim("reverse_traceability", score: 32_402.84, grade: "F",
                                median: 1_000_000.0, median_grade: "F", capped_fraction: 0.9764)
  end
  let(:forward_dim) do
    dim("forward_discoverability", score: 30_992.17, grade: "F",
                                   median: 2.0, median_grade: "A", capped_fraction: 0.0214)
  end

  describe "the pinned verbatim question copy (L17)" do
    it "pins each question's text string byte-exactly" do
      expect(BI::Q1_TEXT).to eq("Implementing a new feature: how much complexity will a developer face?")
      expect(BI::Q2_TEXT).to eq("Fixing a bug: how hard is it to trace where the code you're changing is used?")
      expect(BI::Q3_TEXT).to eq("Breaking something: how many use cases can a single change put at risk?")
      expect(BI::Q4_TEXT).to eq("Implementing a new feature: how many steps does a new flow travel end-to-end?")
      expect(BI::Q5_TEXT).to eq("Fixing a bug: how deep is the trace from a use case down to the code?")
      expect(BI::BF_TEXT).to eq("Branching")
      expect(BI::RC_TEXT).to eq("Reuse")
    end
  end

  # --- v0.13: the Reuse compass line (copy table, byte-pinned; worked numbers
  # = the live-verified app-management compass — 02-verification.md) ----------
  describe "the pinned Reuse compass copy table (v0.13, advisory wording)" do
    def compass(reuse_mean: 2.4, reuse_median: 1.0, booths: nil, extraction: nil)
      booths ||= [
        RS::Reusability::TollBooth.new(symbol: "LandingPageThemesController#content_block_type",
                                       blast: 4, mass_savings: 4),
        RS::Reusability::TollBooth.new(symbol: "AppsController#serialize_navigation_tabs",
                                       blast: 3, mass_savings: 3)
      ]
      extraction ||= [
        RS::Reusability::Extraction.new(symbol: "Api::V1::LandingPageThemesController#build_style",
                                        collapse: 16.0, leverage: 32.0)
      ]
      RS::Reusability.new(
        reuse_index: RS::Reusability::ReuseIndex.new(mean: reuse_mean, median: reuse_median),
        unshared_fraction: 0.5,
        toll_booths: booths, extraction: extraction,
        leverage: RS::Reusability::LeverageStats.new(mean: 3.1, median: 2.0, count: 107)
      )
    end

    def rc_answer(reusability)
      BI.questions(context_with(reusability: reusability))
        .find { |q| q.id == "rc" }&.answer
    end

    it "full form → the plan-pinned three-clause line (advisory: candidates, never mandates)" do
      expect(rc_answer(compass)).to eq(
        "the average node serves 2.4 use cases (median 1); 2 toll booths (bypassing saves ~7 mass); " \
        "top extraction candidate Api::V1::LandingPageThemesController#build_style (collapse ×16.0)"
      )
    end

    it "reachability unknown (nil reuse index) → the reuse clause drops, never '0 use cases'" do
      expect(rc_answer(compass(reuse_mean: nil, reuse_median: nil))).to eq(
        "2 toll booths (bypassing saves ~7 mass); " \
        "top extraction candidate Api::V1::LandingPageThemesController#build_style (collapse ×16.0)"
      )
    end

    it "singular booth + unknown blast → '1 toll booth' with NO savings parenthetical (never a fabricated 0)" do
      one = [RS::Reusability::TollBooth.new(symbol: "Foo#fwd", blast: nil, mass_savings: nil)]
      expect(rc_answer(compass(booths: one))).to eq(
        "the average node serves 2.4 use cases (median 1); 1 toll booth; " \
        "top extraction candidate Api::V1::LandingPageThemesController#build_style (collapse ×16.0)"
      )
    end

    it "no extraction candidate → the clause drops; a real 0-booth verdict still counts" do
      expect(rc_answer(compass(booths: [], extraction: []))).to eq(
        "the average node serves 2.4 use cases (median 1); 0 toll booths"
      )
    end

    it "block absent → NO line; the honest-blank form (vty gate) → NO line (never a lone '0 toll booths')" do
      expect(rc_answer(nil)).to be_nil
      blank = RS::Reusability.new(
        reuse_index: RS::Reusability::ReuseIndex.new(mean: nil, median: nil),
        unshared_fraction: nil, toll_booths: [], extraction: [], leverage: nil
      )
      expect(rc_answer(blank)).to be_nil
    end
  end

  # --- v0.12 W-CLI-B: the Q1 Variety+Mass detail line (copy table, byte-pinned;
  # worked numbers = the MEASURED L15 FULL execute anchor 57 = 16 + 41) --------
  describe "the pinned Variety+Mass copy table (v0.12, A7)" do
    def vm(score: 57.0, median: 57.0, capped: 0.0, variety: 16.0, mass: 41.0)
      RS::VarietyMass.new(
        score: score, median: median, count: 2,
        capped_fraction: capped, fallback_fraction: 0.0,
        variety: variety && RS::VarietyMass::Component.new(mean: variety, median: variety, count: 2),
        mass:    mass && RS::VarietyMass::Component.new(mean: mass, median: mass, count: 2)
      )
    end

    def q1_line(variety_mass)
      q1 = BI.questions(context_with(scores: [forward_dim], variety_mass: variety_mass))
             .find { |q| q.id == "q1" }
      q1.detail_lines.grep(/\Avariety \+ mass/).first
    end

    it "components present, reconciling → the '=' equation form (the A7 common case)" do
      expect(q1_line(vm)).to eq(
        "variety + mass: complexity 57.0 = variety 16.0 + mass 41.0 (median 57.0)"
      )
    end

    it "capped 0 < f < 0.5 → equation + lower-bound note, real median kept" do
      expect(q1_line(vm(capped: 0.021))).to eq(
        "variety + mass: complexity 57.0 = variety 16.0 + mass 41.0 (median 57.0) — 2.1% of routes at cap (lower bound)"
      )
    end

    it "capped f >= 0.5 → 'at cap' median cell (one cap vocabulary — median_cell/cap_note reused verbatim)" do
      expect(q1_line(vm(capped: 0.5))).to eq(
        "variety + mass: complexity 57.0 = variety 16.0 + mass 41.0 (median at cap) — 50.0% of routes at cap (lower bound)"
      )
    end

    it "components absent → composite-only copy" do
      expect(q1_line(vm(variety: nil, mass: nil))).to eq(
        "variety + mass: complexity 57.0 (median 57.0)"
      )
    end

    it "non-reconciling components → the comma form (copy degrades, never lies)" do
      expect(q1_line(vm(mass: 41.5))).to eq(
        "variety + mass: complexity 57.0, variety 16.0, mass 41.5 (median 57.0)"
      )
    end

    it "block absent or N/A → NO line (Q1 renders byte-identically to v0.10.0)" do
      expect(q1_line(nil)).to be_nil
      na = RS::VarietyMass.new(score: nil, median: nil, count: 0)
      expect(q1_line(na)).to be_nil
    end
  end

  describe "the I8 worked examples (byte-exact answers)" do
    it "q3: the measured nexus blast numbers" do
      qs = BI.questions(context_with(blast_radius: blast))
      q3 = qs.find { |q| q.id == "q3" }
      expect(q3.answer).to eq(
        "the worst single node is reachable from 1569 of 1611 use cases (97.4%) — p90 3, median 1"
      )
      expect(q3.grade).to be_nil # ungraded row
      # factors displayed SEPARATELY (R7) — the product is never printed
      expect(q3.detail_lines).to eq(
        ["worst offenders: Router#dispatch (1569 use cases, +7.5 coupling); App#boot (900 use cases)"]
      )
    end

    it "q2: capped reverse dimension → median 'at cap' + lower-bound note" do
      qs = BI.questions(context_with(scores: [reverse_dim]))
      q2 = qs.find { |q| q.id == "q2" }
      expect(q2.answer).to eq(
        "cost mean 32402.8 (F, median: F) · median at cap — 97.6% of routes at cap (lower bound)"
      )
      expect(q2.grade).to eq("F")
    end

    it "q4: depth medians pin to one decimal; the worst clause drops (no max in 1.6 — C3)" do
      qs = BI.questions(context_with(forward_depth: fwd_depth))
      q4 = qs.find { |q| q.id == "q4" }
      expect(q4.answer).to eq("a typical use case is 2.0 functions deep (mean 2.8)")
    end

    it "q5: reverse depth" do
      qs = BI.questions(context_with(reverse_depth: rev_depth))
      q5 = qs.find { |q| q.id == "q5" }
      expect(q5.answer).to eq("a typical trace is 3.0 functions deep (mean 3.4)")
    end

    it "bf: median-FIRST (L15 — the mean is degenerate-dominated)" do
      qs = BI.questions(context_with(branching_factor: branching))
      bf = qs.find { |q| q.id == "bf" }
      expect(bf.answer).to eq("each step of tracing multiplies the choices ×2.42 (median; mean 2649.6)")
      expect(bf.grade).to be_nil
    end
  end

  describe "cap-note thresholds" do
    it "renders NO cap note at capped_fraction 0 (and none when nil — unknown is not zero)" do
      zero = dim("reverse_traceability", score: 61.0, grade: "C", median: 30.0, capped_fraction: 0.0)
      q2 = BI.questions(context_with(scores: [zero])).find { |q| q.id == "q2" }
      expect(q2.answer).to eq("cost mean 61.0 (C) · median 30.0")

      unknown = dim("reverse_traceability", score: 61.0, grade: "C", median: 30.0)
      q2 = BI.questions(context_with(scores: [unknown])).find { |q| q.id == "q2" }
      expect(q2.answer).to eq("cost mean 61.0 (C) · median 30.0")
    end

    it "annotates 0 < f < 0.5 with the lower-bound note but keeps the real median number" do
      partial = dim("reverse_traceability", score: 61.0, grade: "C", median: 30.0, capped_fraction: 0.12)
      q2 = BI.questions(context_with(scores: [partial])).find { |q| q.id == "q2" }
      expect(q2.answer).to eq("cost mean 61.0 (C) · median 30.0 — 12.0% of routes at cap (lower bound)")
    end

    it "renders 'at cap' instead of the falsely-precise median at f >= 0.5" do
      capped = dim("reverse_traceability", score: 61.0, grade: "C", median: 1_000_000.0, capped_fraction: 0.5)
      q2 = BI.questions(context_with(scores: [capped])).find { |q| q.id == "q2" }
      expect(q2.answer).to eq("cost mean 61.0 (C) · median at cap — 50.0% of routes at cap (lower bound)")
    end
  end

  describe "q1 sourcing (entrypoints first, dimension fallback)" do
    it "reads mean/median from the committed entrypoints block with the by-category detail line" do
      ep = RS::EntrypointCount.new(
        total: 4, count: 4, by_category: { "controllers" => 4 },
        mean: 27.14, median: 12.0,
        by_category_cost: { "controllers" => { "mean" => 30.0, "median" => 14.0, "grade" => "C" } }
      )
      q1 = BI.questions(context_with(entrypoints: ep, scores: [forward_dim])).find { |q| q.id == "q1" }
      expect(q1.answer).to eq(
        "cost mean 27.1 (F, median: A) · median 12.0 — 2.1% of routes at cap (lower bound)"
      )
      expect(q1.detail_lines).to eq(["by category: controllers mean 30.0 / median 14.0 (C)"])
      expect(q1.grade).to eq("F")
    end

    it "falls back to the forward dimension on a v1 scores-bearing doc (mean+grade only, no median clause)" do
      v1_fwd = dim("forward_discoverability", score: 82.0, grade: "B")
      q1 = BI.questions(context_with(scores: [v1_fwd])).find { |q| q.id == "q1" }
      expect(q1.answer).to eq("cost mean 82.0 (B)")
      expect(q1.detail_lines).to eq([])
    end
  end

  describe "omission, never fabrication" do
    it "returns [] on an all-nil context (both formatters omit the whole section)" do
      expect(BI.questions(context_with)).to eq([])
    end

    it "omits each question independently when its source struct is nil" do
      qs = BI.questions(context_with(blast_radius: blast, forward_depth: fwd_depth))
      expect(qs.map(&:id)).to eq(%w[q3 q4])
    end

    it "omits q3 on the engine N/A blast form (zero entrypoints — never '0 use cases at risk')" do
      na = RS::BlastRadius.new(
        max: nil, p90: nil, median: nil, mean: nil,
        reached_nodes: 0, total_nodes: 4, total_entrypoints: 0,
        pct_use_cases_hit_by_worst: nil, worst: []
      )
      qs = BI.questions(context_with(blast_radius: na, scores: [forward_dim]))
      expect(qs.map(&:id)).to eq(%w[q1]) # q1 still renders; q3 omitted
    end

    it "omits q4/q5/bf on the engine degenerate stat form (median nil, count 0)" do
      empty = RS::DepthStats.new(mean: nil, median: nil, count: 0)
      qs = BI.questions(context_with(forward_depth: empty, reverse_depth: empty,
                                     branching_factor: RS::BranchingFactor.new(mean: nil, median: nil, count: 0)))
      expect(qs).to eq([])
    end

    it "orders answerable questions q1..bf" do
      qs = BI.questions(context_with(
                          scores: [reverse_dim, forward_dim],
                          blast_radius: blast, forward_depth: fwd_depth,
                          reverse_depth: rev_depth, branching_factor: branching
                        ))
      expect(qs.map(&:id)).to eq(%w[q1 q2 q3 q4 q5 bf])
    end
  end

  # --- v0.11 W-C T9: the L17 nil-tolerance matrix, doc-shaped ------------------
  #
  # Each row builds the RenderContext through the REAL parsers (the exact
  # calls Reconnect.from_cache / the legacy path make), so the matrix pins the
  # end-to-end read path per doc vintage — never just synthetic structs.
  describe "the L17 nil-tolerance matrix (T9)" do
    # Mirror Reconnect.from_cache's parser calls for a committed aggregate doc.
    def context_from_aggregate(doc)
      context_with(
        scores:           RS.from_findings(doc, nil),
        entrypoints:      RS.entrypoints_from_aggregate(doc),
        blast_radius:     RS.blast_radius_from_aggregate(doc),
        forward_depth:    RS.forward_depth_from_aggregate(doc),
        reverse_depth:    RS.reverse_depth_from_aggregate(doc),
        branching_factor: RS.branching_factor_from_aggregate(doc),
        variety_mass:     RS.variety_mass_from_aggregate(doc),
        reusability:      RS.reusability_from_aggregate(doc)
      )
    end

    # Mirror the legacy Reconnect#call parser calls for an opaque findings doc.
    def context_from_findings(doc, resolver)
      context_with(
        scores:           RS.from_findings(doc, resolver),
        blast_radius:     RS.blast_radius_from_findings(doc, resolver),
        forward_depth:    RS.forward_depth_from_findings(doc),
        reverse_depth:    RS.reverse_depth_from_findings(doc),
        branching_factor: RS.branching_factor_from_findings(doc),
        variety_mass:     RS.variety_mass_from_findings(doc),
        reusability:      RS.reusability_from_findings(doc, resolver)
      )
    end

    let(:v2_scores) do
      { "forward_discoverability" => { "grade" => "B", "score" => 82.0 },
        "reverse_traceability"    => { "grade" => "C", "score" => 61.0 } }
    end
    let(:v3_blocks) do
      {
        "blast_radius" => {
          "max" => 1569, "p90" => 3.0, "median" => 1.0, "mean" => 121.38,
          "reached_nodes" => 5506, "total_nodes" => 16_173, "total_entrypoints" => 1611,
          "pct_use_cases_hit_by_worst" => 0.9739,
          "worst" => [{ "symbol" => "Router#dispatch", "use_cases_affected" => 1569,
                        "added_coupling" => 7.5 }]
        },
        "forward_depth"    => { "mean" => 2.83, "median" => 2.0, "count" => 1611 },
        "reverse_depth"    => { "mean" => 3.42, "median" => 3.0, "count" => 5506 },
        "branching_factor" => { "mean" => 2649.6, "median" => 2.416, "count" => 1611 }
      }
    end

    it "row 1 — v1 aggregate, no scores: NO questions (both formatters omit the section)" do
      doc = { "serializer_version" => 1, "generator" => { "tool" => "t" } }
      expect(BI.questions(context_from_aggregate(doc))).to eq([])
    end

    it "row 2 — v1 aggregate + scores: q1/q2 render mean+grade only (no median clause)" do
      doc = { "serializer_version" => 1, "scores" => v2_scores }
      qs = BI.questions(context_from_aggregate(doc))

      expect(qs.map(&:id)).to eq(%w[q1 q2])
      expect(qs.find { |q| q.id == "q1" }.answer).to eq("cost mean 82.0 (B)")
      expect(qs.find { |q| q.id == "q2" }.answer).to eq("cost mean 61.0 (C)")
    end

    it "row 3 — v2 aggregate (today's caches): q1 full v2, q2 median ABSENT (the v2 gap)" do
      doc = {
        "serializer_version" => 2,
        "scores" => v2_scores,
        "entrypoints" => { "total" => 4, "count" => 4,
                           "by_category" => { "controllers" => 4 },
                           "mean" => 27.14, "median" => 12.0 }
      }
      qs = BI.questions(context_from_aggregate(doc))

      expect(qs.map(&:id)).to eq(%w[q1 q2])
      expect(qs.find { |q| q.id == "q1" }.answer).to eq("cost mean 27.1 (B) · median 12.0")
      expect(qs.find { |q| q.id == "q2" }.answer).to eq("cost mean 61.0 (C)") # no median in v2
    end

    it "row 4 — v3 aggregate over engine-1.5 findings: q1/q2 full (median carried), no 1.6 questions" do
      doc = {
        "serializer_version" => 3,
        "scores" => {
          "forward_discoverability" => { "grade" => "B", "score" => 82.0, "median" => 12.0 },
          "reverse_traceability"    => { "grade" => "C", "score" => 61.0, "median" => 30.0 }
        },
        "entrypoints" => { "total" => 4, "count" => 4,
                           "by_category" => { "controllers" => 4 },
                           "mean" => 27.14, "median" => 12.0 }
      }
      qs = BI.questions(context_from_aggregate(doc))

      expect(qs.map(&:id)).to eq(%w[q1 q2]) # 1.5 engine → NO 1.6 blocks, q3..bf omitted
      expect(qs.find { |q| q.id == "q2" }.answer).to eq("cost mean 61.0 (C) · median 30.0")
    end

    it "row 5 — v3 aggregate over engine-1.6: ALL six questions render" do
      doc = {
        "serializer_version" => 3,
        "scores" => {
          "forward_discoverability" => { "grade" => "F", "score" => 30_992.17, "median" => 2.0,
                                         "median_grade" => "A", "capped_fraction" => 0.0214 },
          "reverse_traceability"    => { "grade" => "F", "score" => 32_402.84, "median" => 1_000_000.0,
                                         "median_grade" => "F", "capped_fraction" => 0.9764 }
        },
        "entrypoints" => { "total" => 1611, "count" => 1611,
                           "by_category" => { "controllers" => 1611 },
                           "mean" => 30_992.17, "median" => 2.0 }
      }.merge(v3_blocks)
      qs = BI.questions(context_from_aggregate(doc))

      expect(qs.map(&:id)).to eq(%w[q1 q2 q3 q4 q5 bf])
      expect(qs.find { |q| q.id == "q3" }.answer).to eq(
        "the worst single node is reachable from 1569 of 1611 use cases (97.4%) — p90 3, median 1"
      )
      # worst symbols VERBATIM from the committed (real-name) aggregate
      expect(qs.find { |q| q.id == "q3" }.detail_lines.first).to include("Router#dispatch")
    end

    it "row 6 — legacy opaque findings-1.6 + id-map: ALL six, worst ids RESOLVED" do
      findings = {
        "findings_schema_version" => "1.6",
        "scores" => {
          "forward_discoverability" => { "grade" => "F", "score" => 30_992.17, "median" => 2.0 },
          "reverse_traceability"    => { "grade" => "F", "score" => 32_402.84, "median" => 3.0 },
          "blast_radius" => v3_blocks["blast_radius"].merge(
            "worst" => [{ "node" => "n_1", "use_cases_affected" => 1569, "added_coupling" => 7.5 }]
          ),
          "forward_depth"    => v3_blocks["forward_depth"],
          "reverse_depth"    => v3_blocks["reverse_depth"],
          "branching_factor" => v3_blocks["branching_factor"]
        }
      }
      resolver = Archbuddy::Report::Reconnect::IdMapResolver.new(
        "ids" => { "n_1" => { "symbol" => "Router#dispatch", "file" => "a.rb", "line" => 1 } }
      )
      qs = BI.questions(context_from_findings(findings, resolver))

      expect(qs.map(&:id)).to eq(%w[q1 q2 q3 q4 q5 bf])
      expect(qs.find { |q| q.id == "q3" }.detail_lines).to eq(
        ["worst offenders: Router#dispatch (1569 use cases, +7.5 coupling)"]
      )
    end

    it "row 7 — the engine N/A blast form (zero entrypoints), doc-shaped: q3 omitted, q1/q2 render" do
      doc = {
        "serializer_version" => 3,
        "scores" => v2_scores,
        "blast_radius" => {
          "max" => nil, "p90" => nil, "median" => nil, "mean" => nil,
          "reached_nodes" => 0, "total_nodes" => 4, "total_entrypoints" => 0,
          "pct_use_cases_hit_by_worst" => nil, "worst" => []
        }
      }
      qs = BI.questions(context_from_aggregate(doc))

      expect(qs.map(&:id)).to eq(%w[q1 q2]) # q3 OMITTED — never "0 use cases at risk"
    end

    # --- v0.12 W-CLI-B (serializer v4 / findings 1.7) rows 8–10 --------------
    # These are also the A8-reassigned findings-1.7 tolerance coverage: a 1.7
    # doc renders through the REAL extended parser set with zero raises, and
    # the pre-1.7 rows 1–7 above prove byte-stability through the same set.

    let(:v4_vm_block) do
      { "score" => 57.0, "median" => 57.0, "count" => 2,
        "capped_fraction" => 0.0, "fallback_fraction" => 0.5,
        "variety" => { "mean" => 16.0, "median" => 16.0, "count" => 2 },
        "mass"    => { "mean" => 41.0, "median" => 41.0, "count" => 2 } }
    end
    let(:row5_doc) do
      {
        "serializer_version" => 3,
        "scores" => {
          "forward_discoverability" => { "grade" => "F", "score" => 30_992.17, "median" => 2.0,
                                         "median_grade" => "A", "capped_fraction" => 0.0214 },
          "reverse_traceability"    => { "grade" => "F", "score" => 32_402.84, "median" => 1_000_000.0,
                                         "median_grade" => "F", "capped_fraction" => 0.9764 }
        },
        "entrypoints" => { "total" => 1611, "count" => 1611,
                           "by_category" => { "controllers" => 1611 },
                           "mean" => 30_992.17, "median" => 2.0 }
      }.merge(v3_blocks)
    end

    it "row 8 — v4 aggregate over engine-1.7: all six render AND q1 carries the pinned VM line" do
      doc = row5_doc.merge("serializer_version" => 4, "variety_mass" => v4_vm_block)
      qs = BI.questions(context_from_aggregate(doc))

      expect(qs.map(&:id)).to eq(%w[q1 q2 q3 q4 q5 bf])
      q1 = qs.find { |q| q.id == "q1" }
      expect(q1.detail_lines).to include(
        "variety + mass: complexity 57.0 = variety 16.0 + mass 41.0 (median 57.0)"
      )
    end

    it "row 9 — v4 aggregate whose variety_mass is the N/A form: q1 detail byte-equal to row 5 (no VM line)" do
      row5_q1 = BI.questions(context_from_aggregate(row5_doc)).find { |q| q.id == "q1" }
      na = { "score" => nil, "median" => nil, "count" => 0,
             "capped_fraction" => nil, "fallback_fraction" => nil,
             "variety" => { "mean" => nil, "median" => nil, "count" => 0 },
             "mass"    => { "mean" => nil, "median" => nil, "count" => 0 } }
      doc = row5_doc.merge("serializer_version" => 4, "variety_mass" => na)
      q1 = BI.questions(context_from_aggregate(doc)).find { |q| q.id == "q1" }

      expect(q1.detail_lines).to eq(row5_q1.detail_lines)
      expect(q1.answer).to eq(row5_q1.answer)
    end

    it "row 10 — legacy opaque findings-1.7 + id-map: the VM line renders identically (resolver never consulted)" do
      findings = {
        "findings_schema_version" => "1.7",
        "scores" => {
          "forward_discoverability" => { "grade" => "F", "score" => 30_992.17, "median" => 2.0 },
          "variety_mass" => v4_vm_block.merge("hotspots" => %w[n_1 n_2])
        }
      }
      resolver = Archbuddy::Report::Reconnect::IdMapResolver.new("ids" => {})
      q1 = BI.questions(context_from_findings(findings, resolver)).find { |q| q.id == "q1" }

      expect(q1.detail_lines).to include(
        "variety + mass: complexity 57.0 = variety 16.0 + mass 41.0 (median 57.0)"
      )
    end

    # --- v0.13 (serializer v5 / findings 1.8) rows 11–13 ----------------------
    # The findings-1.8 tolerance coverage: a 1.8 doc renders through the REAL
    # extended parser set with zero raises; rows 1–10 above prove the pre-1.8
    # vintages stay byte-stable through the same set (rc simply absent).

    let(:v5_reusability_block) do
      { "reuse_index"       => { "mean" => 2.4, "median" => 1.0 },
        "unshared_fraction" => 0.5,
        "toll_booths"       => [{ "symbol" => "LandingPageThemesController#content_block_type",
                                  "blast" => 4, "mass_savings" => 4 }],
        "extraction"        => [{ "symbol" => "Api::V1::LandingPageThemesController#build_style",
                                  "collapse" => 16.0, "leverage" => 32.0 }],
        "leverage"          => { "mean" => 3.1, "median" => 2.0, "count" => 107 } }
    end

    it "row 11 — v5 aggregate over engine-1.8: all seven render, rc carries the pinned compass line" do
      doc = row5_doc.merge("serializer_version" => 5, "reusability" => v5_reusability_block)
      qs = BI.questions(context_from_aggregate(doc))

      expect(qs.map(&:id)).to eq(%w[q1 q2 q3 q4 q5 bf rc])
      expect(qs.find { |q| q.id == "rc" }.answer).to eq(
        "the average node serves 2.4 use cases (median 1); 1 toll booth (bypassing saves ~4 mass); " \
        "top extraction candidate Api::V1::LandingPageThemesController#build_style (collapse ×16.0)"
      )
    end

    it "row 12 — v5 aggregate whose reusability is the honest-blank form: rc OMITTED, rest byte-equal to row 5" do
      row5_qs = BI.questions(context_from_aggregate(row5_doc))
      blank = { "reuse_index"       => { "mean" => nil, "median" => nil },
                "unshared_fraction" => nil,
                "toll_booths"       => [], "extraction" => [],
                "leverage"          => { "mean" => nil, "median" => nil, "count" => 0 } }
      doc = row5_doc.merge("serializer_version" => 5, "reusability" => blank)
      qs = BI.questions(context_from_aggregate(doc))

      expect(qs.map(&:id)).to eq(%w[q1 q2 q3 q4 q5 bf]) # no lone "0 toll booths"
      expect(qs.map(&:answer)).to eq(row5_qs.map(&:answer))
    end

    it "row 13 — legacy opaque findings-1.8 + id-map: rc renders with worst ids RESOLVED" do
      findings = {
        "findings_schema_version" => "1.8",
        "scores" => {
          "forward_discoverability" => { "grade" => "F", "score" => 30_992.17, "median" => 2.0 },
          "reusability_compass" => {
            "reuse_index"       => { "mean" => 2.4, "median" => 1.0 },
            "unshared_fraction" => 0.5,
            "toll_booths"       => [{ "node" => "n_tb", "blast" => 4, "mass_savings" => 4 }],
            "extraction"        => [{ "node" => "n_ex", "collapse" => 16.0, "leverage" => 32.0 }],
            "leverage"          => { "mean" => 3.1, "median" => 2.0, "count" => 107 }
          }
        }
      }
      resolver = Archbuddy::Report::Reconnect::IdMapResolver.new(
        "ids" => {
          "n_tb" => { "symbol" => "LandingPageThemesController#content_block_type", "file" => "a.rb", "line" => 1 },
          "n_ex" => { "symbol" => "Api::V1::LandingPageThemesController#build_style", "file" => "b.rb", "line" => 2 }
        }
      )
      rc = BI.questions(context_from_findings(findings, resolver)).find { |q| q.id == "rc" }

      expect(rc.answer).to eq(
        "the average node serves 2.4 use cases (median 1); 1 toll booth (bypassing saves ~4 mass); " \
        "top extraction candidate Api::V1::LandingPageThemesController#build_style (collapse ×16.0)"
      )
    end
  end

  describe "detail-line conventions" do
    it "q4 renders the per-category depth line when the engine grouped (honest absence otherwise)" do
      grouped = RS::DepthStats.new(
        mean: 2.83, median: 2.0, count: 1611,
        by_category: { "controllers" => { "mean" => 2.9, "median" => 2.0, "count" => 1200 } }
      )
      q4 = BI.questions(context_with(forward_depth: grouped)).find { |q| q.id == "q4" }
      expect(q4.detail_lines).to eq(["by category: controllers mean 2.9 / median 2.0"])
    end

    it "drops the coupling suffix on a nil added_coupling (never a fabricated 0)" do
      solo = RS::BlastRadius.new(
        max: 9, p90: 2.0, median: 1.0, mean: 1.5,
        reached_nodes: 3, total_nodes: 5, total_entrypoints: 9,
        pct_use_cases_hit_by_worst: 1.0,
        worst: [RS::BlastRadius::Worst.new(symbol: "A#b", use_cases_affected: 9, added_coupling: nil)]
      )
      q3 = BI.questions(context_with(blast_radius: solo)).find { |q| q.id == "q3" }
      expect(q3.detail_lines).to eq(["worst offenders: A#b (9 use cases)"])
    end
  end
end
