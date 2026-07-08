# frozen_string_literal: true

require "archbuddy/report"
require "archbuddy/report/reconnect"
require "archbuddy/report/ranker"
require "archbuddy/report/formatter"
require "architecture_auditor"
require "json"

# R1: the reporter SURFACES the v0.7 multiplexer_proxy smell (findings 1.4
# `scores.multiplexer_proxies`) as an ADDITIVE section across every formatter,
# VERBATIM worst-first (D17 — never re-ranked, never recomputed). It handles
# BOTH producer shapes: the LEGACY opaque `{node, added_coupling}` (resolved via
# the id-map) and the COMMITTED real-name `{symbol, added_coupling}` (read with
# NO id-map). Absent → section omitted; empty → honest "(none)" note (NEVER a
# fabricated verdict).
RSpec.describe "Reporter multiplexer_proxy smell (R1)" do
  let(:fixtures)   { File.expand_path("../fixtures/report", __dir__) }
  let(:id_map_yml) { File.join(fixtures, "id_map_fixture.yml") }
  let(:v14_yml)    { File.join(fixtures, "findings_v14_multiplexer_fixture.yml") }
  let(:v14_empty)  { File.join(fixtures, "findings_v14_empty_smell_fixture.yml") }
  let(:v11_yml)    { File.join(fixtures, "findings_v11_fixture.yml") } # 1.1, NO smell key
  let(:v10_yml)    { File.join(fixtures, "findings_fixture.yml") }     # 1.0, NO scores block

  def result_for(findings)
    Archbuddy::Report::Reconnect.from_files(
      findings_path: findings, id_map_path: id_map_yml
    ).call
  end

  def context_for(findings)
    result = result_for(findings)
    ranker = Archbuddy::Report::Ranker.new(result)
    Archbuddy::Report::Formatter::RenderContext.new(
      ranked:              ranker.ranked,
      class_rollups:       ranker.class_rollups,
      generator:           result.findings_doc["generator"],
      graph:               nil,
      resolver:            Archbuddy::Report::Reconnect::IdMapResolver.new(result.id_map),
      scores:              result.scores,
      connectivity:        result.connectivity,
      multiplexer_proxies: result.multiplexer_proxies
    )
  end

  def render(findings, format)
    Archbuddy::Report::Formatter.for(format).new(context_for(findings)).render
  end

  # --- model: parse both producer shapes --------------------------------------

  describe "MultiplexerProxy model" do
    it "de-anonymizes the LEGACY opaque {node, added_coupling} form worst-first (VERBATIM)" do
      proxies = result_for(v14_yml).multiplexer_proxies
      expect(proxies.map(&:symbol)).to eq(
        ["Billing#charge", "User#save", "<external sink ext_e4c31576a772>"]
      )
      # order preserved verbatim (not re-sorted) — worst added_coupling first
      expect(proxies.map(&:added_coupling)).to eq([12.5, 4.0, 1.0])
    end

    it "resolves a proxy node absent from the id-map gracefully (no raise)" do
      ghost = result_for(v14_yml).multiplexer_proxies.last
      expect { ghost.where }.not_to raise_error
      expect(ghost.location).not_to be_resolved
      expect(ghost.symbol).to include("<external")
    end

    it "returns [] (not nil) for a scored doc with an empty smell list" do
      expect(result_for(v14_empty).multiplexer_proxies).to eq([])
    end

    it "returns nil for a 1.1 doc with a scores block but NO multiplexer_proxies key" do
      expect(result_for(v11_yml).multiplexer_proxies).to be_nil
    end

    it "returns nil for a 1.0 doc with no scores block at all (back-compat)" do
      expect(result_for(v10_yml).multiplexer_proxies).to be_nil
    end

    # THE R1 GROUND-TRUTH ASSERTION: the report renders the smell from the
    # COMMITTED real-name aggregate DIRECTLY, WITHOUT an id-map/resolver.
    it "reads the committed real-name {symbol, added_coupling} form with NO resolver" do
      committed = {
        "scores" => {
          "multiplexer_proxies" => [
            { "symbol" => "Toast::Loyalty::ProcessOffers#process_all_offers", "added_coupling" => 18.0 },
            { "symbol" => "Billing::Invoice#total",                            "added_coupling" => 6.5 }
          ]
        }
      }
      proxies = Archbuddy::Report::Scores.multiplexer_proxies_from_findings(committed, nil)
      expect(proxies.map(&:symbol)).to eq(
        ["Toast::Loyalty::ProcessOffers#process_all_offers", "Billing::Invoice#total"]
      )
      expect(proxies.map(&:added_coupling)).to eq([18.0, 6.5])
      # real-name path carries no Location (line is display-only, in the id-map)
      expect(proxies.first.location).to be_nil
      expect(proxies.first.where).to eq("Toast::Loyalty::ProcessOffers#process_all_offers")
    end

    it "degrades an ids-only entry (no added_coupling) to a blank coupling, never a fabricated 0" do
      doc = { "scores" => { "multiplexer_proxies" => [{ "symbol" => "A#b" }] } }
      proxy = Archbuddy::Report::Scores.multiplexer_proxies_from_findings(doc, nil).first
      expect(proxy.added_coupling).to be_nil
      expect(proxy.coupling_display).to eq("")
    end
  end

  # --- terminal formatter -----------------------------------------------------

  describe "terminal smell section" do
    it "renders the worst-first list with real symbols + added_coupling" do
      out = render(v14_yml, "terminal")
      expect(out).to include("Multiplexer Proxy Smell")
      expect(out).to match(/1\. Billing#charge.*added_coupling=12\.5000/)
      expect(out).to match(/2\. User#save.*added_coupling=4\.0000/)
      # worst-first order is preserved on the page
      expect(out.index("Billing#charge")).to be < out.index("User#save")
    end

    it "renders an explicit (none) note for a scored-but-empty smell (no fabrication)" do
      out = render(v14_empty, "terminal")
      expect(out).to include("Multiplexer Proxy Smell")
      expect(out).to match(/\(none —/)
    end

    it "OMITS the section entirely for a doc with no scores block (absent != empty)" do
      out = render(v10_yml, "terminal")
      expect(out).not_to include("Multiplexer Proxy Smell")
    end
  end

  # --- structured (yaml/json) -------------------------------------------------

  describe "structured exports" do
    it "yaml export carries multiplexer_proxies worst-first with verbatim coupling" do
      doc = ArchitectureAuditor::Contract::Serializer.load_string(render(v14_yml, "yaml"))
      expect(doc["multiplexer_proxies"].map { |p| p["symbol"] })
        .to eq(["Billing#charge", "User#save", "<external sink ext_e4c31576a772>"])
      expect(doc["multiplexer_proxies"].first["added_coupling"]).to eq(12.5)
    end

    it "json export emits an EMPTY array for a scored-but-empty smell" do
      doc = JSON.parse(render(v14_empty, "json"))
      expect(doc["multiplexer_proxies"]).to eq([])
    end

    it "omits the key entirely for a doc with no scores block" do
      doc = JSON.parse(render(v10_yml, "json"))
      expect(doc).not_to have_key("multiplexer_proxies")
    end
  end

  # --- html -------------------------------------------------------------------

  describe "html section" do
    it "renders a Multiplexer Proxy Smell section with the worst-first table" do
      html = render(v14_yml, "html")
      expect(html).to include("Multiplexer Proxy Smell")
      expect(html).to include("Billing#charge")
      expect(html).to include("12.5000")
      # opaque node id threaded into the data blob for graph annotation
      data = JSON.parse(html[/<script id="archbuddy-data"[^>]*>(.*?)<\/script>/m, 1].gsub('<\/', "</"))
      expect(data["multiplexer_proxies"].first["id"]).to eq("n_e188e5adb49f")
      expect(data["multiplexer_proxies"].first["symbol"]).to eq("Billing#charge")
    end

    it "renders the section with a (none) notice for a scored-but-empty smell" do
      html = render(v14_empty, "html")
      expect(html).to include("Multiplexer Proxy Smell")
      expect(html).to match(/No multiplexer_proxy detected/)
    end

    it "omits the section for a doc with no scores block" do
      html = render(v10_yml, "html")
      expect(html).not_to include("Multiplexer Proxy Smell")
    end
  end
end
