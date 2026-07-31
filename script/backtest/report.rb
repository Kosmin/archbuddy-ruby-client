# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require_relative "cli"
require_relative "author_scan"
require_relative "repos"
require_relative "head_scorer"
require_relative "tier4" # §8 roster reads the LOCKED canon constants (no engine at load)

module Backtest
  # The adoption document (BACKTEST.md) + its machine twin (backtest.json,
  # `archbuddy-backtest/1`), assembled from tier outputs, guarded by the A6
  # author-scan before it may leave tmp/. Deterministic: identical inputs ⇒
  # byte-identical BACKTEST.md (generated_at lives in backtest.json ONLY).
  module Report
    SCHEMA = "archbuddy-backtest/1"
    REDEEM_EP = "Api::V1::RedeemTemplates#PATCH[0]"
    REF_SNAPSHOT = "7eca35c6" # study-era reference (leaderboard source)
    MONO_SNAPSHOT = "0146ad98" # the 2^17 arc value source

    ARC_SENTENCE =
      "PR #2083 grew one use case's argument surface from 2^13 to 2^16 in a single " \
      "change; at the end of the study window that use case was still the repo's #1 " \
      "extraction target (dividend ×65536 — all of it inline decisions), and after " \
      "the port into nexus it had grown again to 2^17 (measured at pr_base `0146ad98…`)."
    REPO_STATE_CAVEAT = "leaderboard values are repo-state inventory, not outcome calibration."

    # Adoption-pitch harness literals (source strings pinned; measured canon —
    # 01-calibration-backtest.md / results/h2_arm_mw.json — never re-derived).
    PITCH_LITERALS = [
      ["review-window hours per changed line", "0.372", "0.146", "×2.5",
       "h2_pr_table.csv medians (0.372231/0.146058)"],
      ["bugfix rate per kLOC-month", "0.342", "0.107",
       "×3.19 (directional: bugfix labels failed the study's validation bar)",
       "excess-bugfix worklist"],
      ["P(Q4 PR slower than Q1 PR)", "66.6%", "—", "Cliff's δ 0.331", "results/h2_arm_mw.json"]
    ].freeze

    GATE_KEYS = %w[
      t0_rollup_433 t1_flag_set_q4 pr2083_net_3000 pr2083_grown_patch0 pr2083_new_b1
      pr2083_fires_exp_growth pr2083_trap_14 pr2083_cli_blocked pr2146_cli_clean
      t3_seven_prs uc2083_branching_13_16 uc2083_dividend_8192_65536 uc2083_mass_73_83
      uc2083_shape_stable rs2083_union_1_sum_1 rs2146_union_2_sum_2 uc2146_new_ep_values
      t3_ep_budget_breach author_scan_clean
    ].freeze

    module_function

    def read_tier(out_dir, name)
      path = File.join(out_dir, "#{name}.json")
      return nil unless File.file?(path)

      JSON.parse(File.read(path, encoding: "UTF-8"))
    end

    # ---- the shipped-CLI gates (pr2083_cli_blocked / pr2146_cli_clean) --------

    # Default runner: replays P3-T7's two gates through exe/archbuddy on
    # archive worktrees (HeadScorer-cached base sides). Injectable for
    # fixture specs. Returns nil when the repos env is absent.
    def default_cli_gate_runner(out_dir)
      lambda do
        repos = Repos.from_env
        entry = repos["thanx/thanx-merchant-api-new"]
        next nil if entry.nil?

        scorer = HeadScorer.new(repos: repos, out: out_dir)
        client_root = File.expand_path("../..", __dir__)
        config_2083 = File.join(client_root, "spec/fixtures/backtest/gate_2083.yml")
        config_default = File.join(client_root, "spec/fixtures/backtest/gate_default.yml")

        blocked = run_cli_gate(entry, scorer, client_root, "f61b758c21d1",
                               resolve_parent(entry, "f61b758c21d1"), config_2083) do |doc, code|
          code == 1 && doc["summary"]["delta"]["net_log2_b_own"] == 3.0 &&
            doc["review_surface"]["union"] == 1
        end
        clean = run_cli_gate(entry, scorer, client_root, "83cc360c2879",
                             "de9630a6f0b9", config_default) do |doc, code|
          code.zero? && doc["summary"]["counts"]["error"].zero? &&
            doc["review_surface"]["union"] == 2
        end
        { "pr2083_cli_blocked" => blocked, "pr2146_cli_clean" => clean }
      end
    end

    def resolve_parent(entry, sha)
      out, _err, status = Open3.capture3("git", "-C", entry.path, "rev-parse", "#{sha}^")
      status.success? ? out.strip : nil
    end

    def run_cli_gate(entry, scorer, client_root, merge_sha, base_sha, config)
      return false if base_sha.nil?

      base = scorer.score("thanx/thanx-merchant-api-new", base_sha)
      return false unless base.ok?

      wt = File.join(File.realpath(Dir.mktmpdir("archbuddy-report-gate-")), "wt")
      system("git", "-C", entry.path, "worktree", "add", "--detach", wt, merge_sha,
             out: File::NULL, err: File::NULL) or return false
      begin
        stdout, _stderr, status = Open3.capture3(
          RbConfig.ruby, File.join(client_root, "exe", "archbuddy"),
          "diff", wt, base_sha, "--base-cache", base.dir, "--config", config,
          "--format", "json", chdir: client_root
        )
        doc = JSON.parse(stdout.force_encoding("UTF-8"))
        yield doc, status.exitstatus
      rescue JSON::ParserError
        false
      ensure
        system("git", "-C", entry.path, "worktree", "remove", "--force", wt,
               out: File::NULL, err: File::NULL)
      end
    end

    # ---- markdown assembly -----------------------------------------------------

    def markdown(tiers, gates, cli_note: nil)
      t1 = tiers["tier1"]
      md = +"# archbuddy backtest — the adoption document\n\n"
      md << header_section(t1)
      md << adoption_section(t1)
      md << leaderboard_section(t1)
      md << tier2_section(tiers["tier2"])
      md << tier3_section(tiers["tier3"])
      md << worked_examples_section(tiers["tier2"])
      md << gates_section(gates)
      md << appendix_section(tiers["tier2"], cli_note)
      md << tier4_section
      md
    end

    IN_SAMPLE_DISCLOSURE =
      "IN-SAMPLE DISCLOSURE: the ExponentialNode threshold (strictly > 2^5) is this " \
      "same corpus's frozen Q4 boundary; Tier 1 restates the study through the tool's " \
      "read/rollup/flag path and is NOT out-of-sample validation. Its non-circular " \
      "content: the cross-implementation reproduction (Tier 0) and the flag RATE — " \
      "the adoption noise cost."

    def header_section(t1)
      disclosure = t1&.dig("markdown_block")&.lines&.grep(/IN-SAMPLE/)&.first&.strip
      disclosure = IN_SAMPLE_DISCLOSURE if disclosure.nil? || disclosure.empty?
      <<~MD
        Toolchain: client #{Archbuddy::VERSION}, engine 0.10.0, serializer 5.
        Corpus: n=433 merged PRs, two repos (thanx/thanx-merchant-api-new,
        thanx/nexus services/merchant-api), window 2025-10-22 → 2026-07-22.

        > #{disclosure}

        > All outcome associations are observational, not causal: complex code attracts
        > harder changes; no randomization was performed.

      MD
    end

    def adoption_section(t1)
      return "## 2. The adoption pitch\n\n_tier 1 not run_\n\n" if t1.nil?

      flagged = t1["flagged"]
      edit = t1["edit_prs"]
      all = t1["all_prs"]
      med = t1["medians"]
      md = +"## 2. The adoption pitch (Tier 1)\n\n"
      md << "| metric | Q4-touch flagged | Q1 unflagged | ratio | source |\n"
      md << "|---|---|---|---|---|\n"
      md << "| flag rate | #{flagged}/#{edit} edit = #{(flagged * 100.0 / edit).round(1)}% " \
            "(#{flagged}/#{all} = #{(flagged * 100.0 / all).round(1)}% of all) | — | — | tier1.json |\n"
      md << "| median merge latency | #{med['flagged'].round(1)} h | #{med['q1'].round(1)} h " \
            "| ×#{(med['flagged'] / med['q1']).round(1)} | tier1.json medians |\n"
      PITCH_LITERALS.each do |metric, q4, q1, ratio, source|
        md << "| #{metric} | #{q4} | #{q1} | #{ratio} | #{source} |\n"
      end
      md << "\n"
    end

    # §2b — the study-era use-case leaderboard (G3: top-10) + the arc.
    def leaderboard_section(t1)
      md = +"### 2b. The use-case leaderboard of the study era\n\n"
      ref = t1 && (t1["inventory"] || []).find { |row| row["sha"].to_s.start_with?(REF_SNAPSHOT) }
      rows = ref && ref["leaderboard_top10"]
      if rows.nil? || rows.empty?
        md << "_tier 1 inventory not available — leaderboard not rendered_\n\n"
        return md
      end

      keys = %w[rank ep kind branching_log2 mass reach files depth dividend
                max_cone_node_log2 cost_note]
      md << "| #{keys.join(' | ')} |\n"
      md << "|#{'---|' * keys.size}\n"
      rows.first(10).each do |row|
        md << "| #{keys.map { |k| row[k].nil? ? '—' : row[k] }.join(' | ')} |\n"
      end
      md << "\n#{ARC_SENTENCE}\n\n#{REPO_STATE_CAVEAT}\n\n"
      md
    end

    # The 2^17 arc value MUST come from the inventory (generation-time assert).
    def arc_value_ok?(t1)
      mono = t1 && (t1["inventory"] || []).find { |row| row["sha"].to_s.start_with?(MONO_SNAPSHOT) }
      dividend = mono && mono.dig("redeem", "dividend")
      dividend == 131_072.0 || dividend == 131_072
    end

    def tier2_section(t2)
      return "## 3. Tier 2 — delta-rule replay\n\n_tier 2 not run_\n\n" if t2.nil?

      md = +"## 3. Tier 2 — delta-rule replay\n\n"
      md << "| rule | n fired | median latency fired (h) | median latency not fired (h) |\n"
      md << "|---|---|---|---|\n"
      (t2["association"] || []).each do |row|
        md << "| #{row['rule']} | #{row['n_fired']} | #{row['median_latency_fired'] || '—'} " \
              "| #{row['median_latency_not_fired'] || '—'} |\n"
      end
      md << "\n#{t2['method_caveat']}\n\n"
      md << "The trap, demonstrated live: the same #2083 pair UNRESTRICTED yields net " \
            "+#{t2.dig('pr2083', 'unrestricted_net')&.round(1)} log2 (global churn) vs the " \
            "PR-scoped +#{t2.dig('pr2083', 'restricted_net')&.round(3)} — the number that " \
            "justifies merge-base isolation in live CI.\n\n"
      md << review_surface_distribution(t2)
      diag = t2["diagnostics"] || {}
      if diag["rs2083_file_level"]
        md << "File-level diagnostic: rs2083_file_level = {union: " \
              "#{diag.dig('rs2083_file_level', 'union')}, sum: " \
              "#{diag.dig('rs2083_file_level', 'sum')}} — #{diag['rs2083_file_level_label']}\n\n"
      end
      md
    end

    def review_surface_distribution(t2)
      dist = t2["review_surface"]
      if dist.nil?
        return "_merge-parent sweep not run_ (the ReviewSurface ∪ distribution is only " \
               "honest on (merge^1, merge) pairs — cone metrics ripple in multi-commit " \
               "windows).\n\n"
      end

      md = +"ReviewSurface ∪ distribution (merge-parent sweep, n=#{dist['n']}): "
      md << %w[p50 p75 p90 p95 p99 max].map { |k| "#{k}=#{dist[k]}" }.join(", ")
      md << ".\n\nAll outcome associations are observational, not causal: complex code " \
            "attracts harder changes; no randomization was performed.\n\n"
      md
    end

    def tier3_section(t3)
      return "## 4. Tier 3 — ratchet counterfactual\n\n_tier 3 not run_\n\n" if t3.nil?

      md = +"## 4. Tier 3 — ratchet counterfactual (#{t3['rows']} scope PRs)\n\n"
      md << t3["trajectory_markdown"].to_s
      ep = t3["ep_budget"]
      if ep
        md << "\nEntrypoints-budget variant (`#{REDEEM_EP}` at budget +0.000, the clean " \
              "(merge^1, merge) pair): verdict **#{ep['verdict']}**, observed " \
              "+#{format('%.3f', ep['observed_log2'])}.\n"
      end
      md << "\n"
    end

    def worked_examples_section(t2)
      md = +"## 5. Worked examples (the Q5 canon)\n\n"
      md << "Node-level (#2083): `#{REDEEM_EP}` 8192 → 65536 branches (Δ +3.000 log2); " \
            "restricted scope net +3.000 breaches a 0-budget ratchet; exit 1.\n\n"
      rows = t2 && t2["ep_rows"]
      if rows && rows["redeem_merge1"]
        base = rows["redeem_merge1"]
        head = rows["redeem_merge"]
        md << "| ep metric | merge^1 | merge |\n|---|---|---|\n"
        md << "| branching_log2 | #{base['branching_log2']} | #{head['branching_log2']} |\n"
        md << "| mass | #{base['mass']} | #{head['mass']} |\n"
        md << "| reach/files/depth | #{base['reach']}/#{base['files']}/#{base['depth']} " \
              "| #{head['reach']}/#{head['files']}/#{head['depth']} |\n"
        md << "| V_now | 2^13 | 2^16 |\n| V_floor | 2^0 | 2^0 |\n"
        md << "| dividend | ×#{base['dividend'].to_i} | ×#{head['dividend'].to_i} |\n"
        md << "| review surface | ∪=#{rows.dig('rs2083', 'union')}/Σ=#{rows.dig('rs2083', 'sum')} | |\n\n"
      else
        md << "_ep-level rows not available (tier 2 ep gate path not run)_\n\n"
      end
      uc = rows && rows["uc2146"]
      if uc
        md << "What clean looks like (#2146): 2 NEW use cases " \
              "(GET[0] {#{uc.dig('GET[0]', 'branching_log2')}, mass #{uc.dig('GET[0]', 'mass')}}, " \
              "PATCH[0] {#{uc.dig('PATCH[0]', 'branching_log2')}, mass #{uc.dig('PATCH[0]', 'mass')}}), " \
              "net +#{format('%.3f', uc['net_log2'])}, RS ∪=#{rows.dig('rs2146', 'union')} — " \
              "landing it required re-verifying nothing pre-existing.\n\n"
      end
      md
    end

    def gates_section(gates)
      md = +"## 6. Gates (#{gates.size} core gates)\n\n| gate | value |\n|---|---|\n"
      gates.each { |name, value| md << "| #{name} | #{value} |\n" }
      md << "\n"
    end

    # §8 — the v0.16 tier-4 reusability-score gate ROSTER. Emitted DETERMINISTICALLY
    # from the LOCKED §2 canon in Tier4 (GATE_FAMILIES + the published anchor
    # constants) — it needs NO live corpus run, so the committed BACKTEST.md is
    # generator output that a warm run reproduces byte-for-byte with OR without the
    # corpus (X-5: rows land via the emitter, never a hand edit regeneration reverts;
    # the anti-drift guard). Live pass/fail is a RUNTIME artifact (tier4.json →
    # backtest.json's `tier4` sibling block; report.rb#generate folds it there), never
    # baked into this doc. The 19-key core `gates` object stays byte-identical. Nodes
    # are named by (file, symbol) only (L6).
    def tier4_section
      n = Tier4::GATE_FAMILIES.size
      base = Tier4::MONSTER_ANCHOR[Tier4::BASE]
      head = Tier4::MONSTER_ANCHOR[Tier4::HEAD]
      rank1 = Tier4::RANK1_ANCHOR
      esc = Tier4::WORST_ESCAPE_ANCHOR
      rows = {
        "G-1a" => "monster `#{Tier4::MONSTER[1]}` base score #{base[0]} (band #{base[1]})",
        "G-1b" => "monster head score #{head[0]} (band #{head[1]}); score_raw drops base→head",
        "G-2" => "rank-1 booth `#{Tier4::RANK1[1]}` #{rank1[0]} (band #{rank1[1]}); 20-booth cohort scores positive",
        "G-3" => "pole exclusivity: no negative-scored booth, no positive-scored non-booth",
        "G-4" => "six-band distribution shares within envelope; n_null 0; fold matches published bands",
        "G-5" => "#2146 new thin entrypoints score 0 (band 0) by deadband",
        "G-8" => "unchanged-tuple nodes carry no score churn across consecutive vintages",
        "G-10" => "escapes score negative; worst `#{Tier4::WORST_ESCAPE[1]}` #{esc[0]} (band #{esc[1]})",
        "G-11" => "per-class signed extremes: monster class headline #{Tier4::MONSTER_CLASS_ROW['headline']}, rank 1",
        "G-12" => "absorb exclusivity: escaping / collapse>2 nodes carry no absorb",
        "G-13" => "absorb band churn-free across consecutive vintages",
        "G-14" => "absorb distribution within the eligibility envelope",
        "G-15" => "zero-predecessor entrypoints carry no absorb"
      }
      md = +"## 8. Tier 4 — reusability score gates (#{n} score gates)\n\n"
      md << "19 core gates (above) + #{n} reusability-score gates assert the LOCKED " \
            "calibration canon on ENGINE-EMITTED findings 1.9 (engine >= #{Tier4::ENGINE_MIN}) " \
            "across #{Tier4::VINTAGES.size} calibration vintages. This roster is generated from " \
            "the gate registry; live pass/fail is a runtime artifact (`tier4.json` → the `tier4` " \
            "block of backtest.json), never baked into this committed doc. Callers converge here; " \
            "nodes are named by (file, symbol) only.\n\n"
      md << "| gate | canon anchor (engine-emitted 1.9) |\n|---|---|\n"
      Tier4::GATE_FAMILIES.each { |g| md << "| #{g} | #{rows.fetch(g)} |\n" }
      md << "\n"
      md
    end

    def appendix_section(t2, cli_note)
      md = +"## 7. Method + privacy appendix\n\n"
      md << "Read-only corpus; per-file column whitelist (author columns unreachable by " \
            "construction); id-map never read; head scores cached under gitignored tmp/; " \
            "worktrees created → used → REMOVED per run; base reads ≈ 2 s from committed " \
            "caches vs 35.4 s/side stateless collect (measured).\n\n"
      md << "Merge-parent sensitivity appendix: "
      md << if t2 && t2["review_surface"]
              "the one-shot `--pairs merge-parent` sweep feeds both the sensitivity check " \
              "and the ReviewSurface distribution above (double collect cost, documented).\n"
            else
              "_merge-parent sweep not run_ (sensitivity appendix renders from the one-shot " \
              "`--pairs merge-parent` sweep when available).\n"
            end
      md << "#{cli_note}\n" if cli_note
      md
    end

    # ---- runner -----------------------------------------------------------------

    def collect_gates(tiers, cli_gates)
      gates = {}
      gates["t0_rollup_433"] = tiers["tier0"]&.dig("gates", "t0_rollup_433") == true
      gates["t1_flag_set_q4"] = tiers["tier1"]&.dig("gates", "t1_flag_set_q4") == true
      %w[pr2083_net_3000 pr2083_grown_patch0 pr2083_new_b1 pr2083_fires_exp_growth
         pr2083_trap_14 uc2083_branching_13_16 uc2083_dividend_8192_65536 uc2083_mass_73_83
         uc2083_shape_stable rs2083_union_1_sum_1 rs2146_union_2_sum_2
         uc2146_new_ep_values].each do |key|
        gates[key] = tiers["tier2"]&.dig("gates", key) == true
      end
      gates["pr2083_cli_blocked"] = cli_gates&.dig("pr2083_cli_blocked") == true
      gates["pr2146_cli_clean"] = cli_gates&.dig("pr2146_cli_clean") == true
      gates["t3_seven_prs"] = tiers["tier3"]&.dig("gates", "t3_seven_prs") == true
      gates["t3_ep_budget_breach"] = tiers["tier3"]&.dig("gates", "t3_ep_budget_breach") == true
      gates
    end

    # @return [Integer] exit code (0 all gates true, 1 any false, 2 generation error)
    def generate(out:, cli_gate_runner: nil)
      out_dir = File.expand_path(out)
      tiers = %w[tier0 tier1 tier2 tier3].to_h { |name| [name, read_tier(out_dir, name)] }
      # Tier 4 (v0.16) is read through a DEDICATED additive call — the 19-key
      # core `gates` object and its eq(19) pin stay untouched (X-5).
      tier4 = read_tier(out_dir, "tier4")

      unless arc_value_ok?(tiers["tier1"])
        warn "error: BACKTEST.md degenerate — generation bug (the 2^17 arc value is not " \
             "131072 in the Tier-1 inventory)"
        return 2
      end

      cli_gates = (cli_gate_runner || default_cli_gate_runner(out_dir)).call
      cli_note = cli_gates.nil? ? "CLI gates skipped: ARCHBUDDY_STUDY_REPOS not set." : nil

      gates = collect_gates(tiers, cli_gates)
      body = markdown(tiers, gates.merge("author_scan_clean" => "(this row mirrors the scan below)"),
                      cli_note: cli_note)

      matches = AuthorScan.scan(body)
      degenerate = AuthorScan.degenerate?(body)
      if degenerate
        warn "error: BACKTEST.md degenerate — generation bug"
        return 2
      end

      gates["author_scan_clean"] = matches.empty?
      # re-render with the final boolean so the table mirrors the json exactly
      body = markdown(tiers, gates, cli_note: cli_note)

      FileUtils.mkdir_p(out_dir)
      if matches.empty?
        File.write(File.join(out_dir, "BACKTEST.md"), body)
      else
        File.write(File.join(out_dir, "BACKTEST.md.REJECTED"), body)
        warn "error: author-scan matched #{matches.size} identifier(s) — BACKTEST.md.REJECTED written"
      end

      doc = {
        "schema" => SCHEMA,
        "generated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "toolchain" => { "client" => Archbuddy::VERSION, "engine" => "0.10.0", "serializer" => 5 },
        "corpus" => { "n_prs" => 433, "window" => "2025-10-22 → 2026-07-22",
                      "repos" => ["thanx/thanx-merchant-api-new", "thanx/nexus"] },
        "tiers" => {
          "t0" => tiers["tier0"]&.slice("compared", "matched"),
          "t1" => tiers["tier1"]&.slice("flagged", "edit_prs", "all_prs", "medians", "inventory"),
          "t2" => tiers["tier2"]&.slice("rows", "skipped", "association", "review_surface",
                                        "diagnostics", "ep_rows"),
          "t3" => tiers["tier3"]&.slice("rows", "trajectory", "ep_budget")
        },
        "gates" => gates
      }
      # v0.16 tier-4 rides as an ADDITIVE sibling block (schema archbuddy-backtest/1
      # unchanged, additive keys only) — never folded into the 19-key `gates`.
      doc["tier4"] = tier4.slice("gate_count", "gates", "vintages", "vintages_absent", "notes") if tier4
      File.write(File.join(out_dir, "backtest.json"), JSON.pretty_generate(doc))

      gates.values.all? ? 0 : 1
    end
  end
end
