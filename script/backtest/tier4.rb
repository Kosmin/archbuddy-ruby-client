# frozen_string_literal: true

require "json"
require "yaml"
require "set"
require "fileutils"
require "open3"
require_relative "cli"
require_relative "corpus"
require_relative "author_scan"
require_relative "repos"
require_relative "graph_rebuild"

module Backtest
  # Tier 4 — the reusability-score gate battery (v0.16, additive to v0.15's
  # frozen 19-gate set: tiers 0–3 stay byte-untouched; this file self-registers
  # tier "4" via the auto-discovery registry). It asserts the LOCKED §2 B-marked
  # gate canon (G-1a, G-1b, G-2, G-3-recount, G-4's six band shares, G-5, G-8,
  # G-10, G-11) PLUS the L9-A absorption-headroom advisory gates (G-12..G-15) on
  # ENGINE-EMITTED findings 1.9 — NEVER a Ruby/Python replica of the formula (that
  # would be the transcription-drift trap the whole arc exists to kill, R1).
  #
  # Every gate regenerates: stored corpus findings are 1.8 (no score keys), so the
  # tier rebuilds each vintage's graph.yml from its snapshot (GraphRebuild) and
  # re-runs the CURRENT engine (≥ 0.11.0). Node identity is resolved via the
  # snapshot id-map INSIDE the harness only, referenced as (file, symbol); id-map
  # values NEVER enter the report (L6) and the A6 author-scan quarantines any leak.
  #
  # Degenerate discipline (calibration §4.4): engine < 0.11.0 → loud skip exit 0;
  # `ARCHBUDDY_STUDY_CORPUS` unset → CLI skips before us; calibration vintages
  # absent from the corpus → loud skip exit 0; a rebuilt vintage with ZERO scored
  # nodes → its gates report false with reason "no scored nodes" (never a vacuous
  # pass); G-5's #2146 head is not a snapshot — it regenerates from the study
  # source repo and SKIPS LOUD with a printed reason when that repo is absent.
  module Tier4
    ENGINE_MIN = "0.11.0"

    # Locked calibration corpus (12-char prefixes; calibration §1.5). Base → mid →
    # head → two-months; the ≥3-vintage churn lock rides consecutive pairs.
    BASE  = "68abf8310626"
    MID   = "7a1dd8959b60"
    HEAD  = "f61b758c21d1"
    TWOMO = "4d24576b1784"
    VINTAGES = [BASE, MID, HEAD, TWOMO].freeze

    # Canon node identities — (file, symbol) ONLY (L6; id-map never emitted).
    MONSTER = ["app/api/api/v1/redeem_templates.rb", "Api::V1::RedeemTemplates#PATCH[0]"].freeze
    RANK1 = ["app/api/api/v1/locations.rb", "Api::V1::Locations#collection"].freeze
    WORST_ESCAPE = ["app/interactors/batch/process_record.rb",
                    "Batch::ProcessRecord#destroy_association"].freeze

    # Archived band-level canon (calibration §2 / p3-calibration.json d8). The
    # histogram is band-integer — ordering-invariant and immune to the published
    # 2-dp vs unrounded-ingredient divergence (V16-F1/F8); the six envelope
    # shares are the §2 G-4 row. Anchor reals are the archive's full-precision
    # published values (never re-rounded — V16-F7 RULE).
    EXPECTED_N = { BASE => 1803, MID => 1823, HEAD => 1824, TWOMO => 1939 }.freeze
    EXPECTED_HIST = {
      BASE => { "-5" => 0, "-4" => 2, "-3" => 4, "-2" => 34, "-1" => 211,
                "0" => 1431, "1" => 22, "2" => 50, "3" => 42, "4" => 7, "5" => 0 },
      MID => { "-5" => 0, "-4" => 2, "-3" => 4, "-2" => 34, "-1" => 213,
               "0" => 1447, "1" => 23, "2" => 49, "3" => 44, "4" => 7, "5" => 0 },
      HEAD => { "-5" => 1, "-4" => 1, "-3" => 4, "-2" => 34, "-1" => 213,
                "0" => 1448, "1" => 23, "2" => 49, "3" => 44, "4" => 7, "5" => 0 },
      TWOMO => { "-5" => 1, "-4" => 1, "-3" => 5, "-2" => 38, "-1" => 235,
                 "0" => 1530, "1" => 24, "2" => 47, "3" => 49, "4" => 9, "5" => 0 }
    }.freeze
    MS_FLOOR = { BASE => 6, MID => 7, HEAD => 7, TWOMO => 8 }.freeze
    MONSTER_ANCHOR = { BASE => [-4.23, -4, -15.0], HEAD => [-4.52, -5, -18.75] }.freeze
    WORST_ESCAPE_ANCHOR = [-2.3, -2, -4.939].freeze
    RANK1_ANCHOR = [4.07, 4, 5.044].freeze
    MONSTER_CLASS_ROW = { "min" => -4.52, "max" => 3.42, "count" => 9,
                          "n_negative" => 1, "n_positive" => 1, "headline" => -4.52 }.freeze
    CLASS_COUNT_HEAD = 374

    # #2146 clean-PR pair (G-5) — head is a transient study worktree, not a
    # snapshot; regenerated from the source repo (calibration §4.3).
    ARCHIVE_REPO = "thanx/thanx-merchant-api-new"
    PR2146_HEAD = "83cc360c2879"
    PR2146_BASE = "de9630a6f0b9"

    # The gate registry — the row count BACKTEST.md/CHANGELOG quote is DERIVED
    # from this list (C-2: "12 score gates" was a sketch; the harness owns the
    # real number). 13 families = 9 B-marked canon + 4 L9-A advisory.
    GATE_FAMILIES = %w[G-1a G-1b G-2 G-3 G-4 G-5 G-8 G-10 G-11 G-12 G-13 G-14 G-15].freeze

    CLIENT_ROOT = File.expand_path("../..", __dir__)

    module_function

    # --------------------------------------------------------------------------
    # Orchestration
    # --------------------------------------------------------------------------

    # @return [Integer] 0 ran-or-skipped-gracefully · 1 ≥1 gate false · 2 tool error
    def run(corpus:, opts:, analyzer: nil, repos: nil)
      unless engine_ok?
        warn "note: tier4 skipped: bundler-resolved engine #{engine_version.inspect} " \
             "< #{ENGINE_MIN} (reusability scores unavailable)"
        return 0
      end

      out_dir = File.expand_path(opts[:out] || CLI::DEFAULT_OUT)
      scratch = File.join(out_dir, "tier4")
      FileUtils.mkdir_p(scratch)
      analyzer ||= method(:analyze)

      resolved = resolve_vintages(corpus)
      if resolved.empty?
        warn "note: tier4 skipped: none of the calibration vintages " \
             "(#{VINTAGES.join(', ')}) are present in the corpus snapshots"
        return 0
      end

      docs = {}
      resolved.each do |prefix, snapshot_dir|
        bundle = build_vintage(prefix, snapshot_dir, scratch, analyzer)
        return 2 if bundle == :tool_error

        docs[prefix] = bundle # a healthy bundle, or :degenerate
      end

      g5 = evaluate_g5(scratch, analyzer, repos)
      gates = Gates.families(docs).merge("G-5" => g5)
      absent = VINTAGES - resolved.keys

      write_report(scratch, out_dir, gates: gates, docs: docs, absent: absent)
    end

    # Locate each calibration vintage's snapshot dir (full-sha dirs; prefix match).
    def resolve_vintages(corpus)
      snap_root = File.join(corpus.root, "snapshots")
      return {} unless File.directory?(snap_root)

      dirs = Dir.children(snap_root).select { |d| File.directory?(File.join(snap_root, d)) }
      VINTAGES.each_with_object({}) do |prefix, acc|
        full = dirs.find { |d| d.start_with?(prefix) }
        acc[prefix] = File.join(snap_root, full) if full
      end
    end

    # Rebuild → analyze → bundle for one vintage.
    # @return [Hash] healthy bundle · :degenerate (zero scored) · :tool_error
    def build_vintage(prefix, snapshot_dir, scratch, analyzer)
      graph_path = File.join(scratch, "graph-#{prefix}.yml")
      findings_path = File.join(scratch, "findings-#{prefix}.yml")

      rebuilt = GraphRebuild.rebuild(snapshot_dir, graph_path)
      ok, log = analyzer.call(graph_path, findings_path)
      unless ok
        warn "error: tier4 engine analyze failed for #{prefix}: #{log.to_s.lines.last&.strip}"
        return :tool_error
      end

      doc = load_findings(findings_path)
      Gates.bundle(prefix, doc, rebuilt) || :degenerate
    rescue ArgumentError => e
      warn "error: tier4 rebuild failed for #{prefix}: #{e.message}"
      :tool_error
    rescue JSON::ParserError, Psych::SyntaxError => e
      warn "error: tier4 could not parse engine findings for #{prefix}: #{e.message}"
      :tool_error
    end

    # engine analyze, bundler-resolved (Q9a — never the stale ~/.archbuddy shim).
    def analyze(graph_path, out_path)
      out, status = Open3.capture2e(
        "bundle", "exec", "architecture-auditor", "analyze", graph_path,
        "--out", out_path, chdir: CLIENT_ROOT
      )
      [status.success? && File.file?(out_path), out]
    end

    # The engine emits YAML (findings.yml); YAML.safe_load also parses the JSON
    # subset, so this stays correct whichever extension a caller uses.
    def load_findings(path)
      YAML.safe_load(File.read(path, encoding: "UTF-8"))
    end

    def engine_ok?
      ver = engine_version
      !ver.nil? && Gem::Version.new(ver) >= Gem::Version.new(ENGINE_MIN)
    end

    def engine_version
      require "architecture_auditor"
      ArchitectureAuditor::VERSION
    rescue LoadError, NameError
      nil
    end

    # G-5: regenerate the #2146 (merge^1, merge) pair from the study source repo
    # and assert every NEW ep (present in head, absent in base) scores 0 / band 0.
    # SKIPS LOUD (never vacuous pass, never false) when the source repo is absent
    # or the head SHA is unresolvable (§4.3).
    # @return [true, false, :skipped]
    def evaluate_g5(scratch, analyzer, repos)
      repos ||= Repos.from_env
      entry = repos[ARCHIVE_REPO]
      if entry.nil?
        warn "note: tier4 G-5 skipped: ARCHBUDDY_STUDY_REPOS lacks #{ARCHIVE_REPO} " \
             "(#2146 head is not a snapshot — regeneration needs the source repo)"
        return :skipped
      end

      head = regenerate_pair_side(entry, PR2146_HEAD, scratch, analyzer)
      base = regenerate_pair_side(entry, PR2146_BASE, scratch, analyzer)
      if head.nil? || base.nil?
        warn "note: tier4 G-5 skipped: could not regenerate the #2146 pair " \
             "(SHA unresolvable or collect/analyze unavailable)"
        return :skipped
      end

      new_eps = head[:by_fs].keys - base[:by_fs].keys
      scored_new = new_eps.filter_map { |fs| head[:reus][head[:by_fs][fs]] }
                          .select { |e| !e["score"].nil? }
      if scored_new.empty?
        warn "note: tier4 G-5 skipped: no new scored eps found in the #2146 head"
        return :skipped
      end

      bad = scored_new.reject { |e| e["score"] == 0.0 && e["score_band"] == 0 }
      unless bad.empty?
        warn "error: tier4 G-5 false: #{bad.size} new #2146 ep(s) did not score 0/band 0 " \
             "(triples #{bad.first(2).map { |e| [e['score'], e['score_band']] }})"
      end
      bad.empty?
    end

    # Detached-worktree collect (retains the id-map) → rebuild → analyze → bundle.
    # Worktree posture: create → use → REMOVE (HeadScorer discipline).
    def regenerate_pair_side(entry, sha, scratch, analyzer)
      return nil unless resolvable?(entry.path, sha)

      wt = File.join(scratch, "wt-#{sha}")
      FileUtils.rm_rf(wt)
      add_ok = system("git", "-C", entry.path, "worktree", "add", "--detach", wt, sha,
                      out: File::NULL, err: File::NULL)
      return nil unless add_ok

      target = entry.target_in(wt)
      collect_ok, = Open3.capture2e("bundle", "exec", "exe/archbuddy", "collect", target,
                                    chdir: CLIENT_ROOT)
      graph_path = File.join(scratch, "graph-2146-#{sha}.yml")
      findings_path = File.join(scratch, "findings-2146-#{sha}.yml")
      rebuilt = GraphRebuild.rebuild(target, graph_path)
      ok, = analyzer.call(graph_path, findings_path)
      return nil unless ok

      Gates.bundle(sha, load_findings(findings_path), rebuilt)
    rescue ArgumentError, JSON::ParserError, Psych::SyntaxError
      nil
    ensure
      if wt && File.directory?(wt)
        system("git", "-C", entry.path, "worktree", "remove", "--force", wt,
               out: File::NULL, err: File::NULL)
        FileUtils.rm_rf(wt)
      end
    end

    def resolvable?(clone, sha)
      _o, _e, st = Open3.capture3("git", "-C", clone, "rev-parse", "--verify", "--quiet",
                                  "#{sha}^{commit}")
      st.success?
    end

    # --------------------------------------------------------------------------
    # Report (additive tier4.json; report.rb folds it as a sibling block)
    # --------------------------------------------------------------------------

    def write_report(scratch, out_dir, gates:, docs:, absent:)
      pass_fail = gates.values.reject { |v| v == :skipped }
      notes = build_notes(docs, absent, gates)
      doc = {
        "schema" => "archbuddy-tier4/1",
        "gate_count" => GATE_FAMILIES.size,
        "vintages" => docs.keys,
        "vintages_absent" => absent,
        "gates" => gates.transform_values { |v| v == :skipped ? "skipped" : v },
        "notes" => notes
      }
      body = JSON.pretty_generate(doc)

      # A6 defence in depth: (file, symbol) carry no author handles/emails, scan anyway.
      matches = AuthorScan.scan(body)
      doc["gates"]["author_scan_clean"] = matches.empty?
      unless matches.empty?
        warn "error: tier4 author-scan matched #{matches.size} identifier(s) — report quarantined"
      end
      body = JSON.pretty_generate(doc)

      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "tier4.json"), body)

      true_ct = gates.count { |_k, v| v == true }
      warn "tier4: #{true_ct}/#{pass_fail.size} score gates true " \
           "(#{gates.count { |_k, v| v == :skipped }} skipped) over #{docs.size} vintage(s)"
      gates.each { |name, ok| warn "error: tier4 gate #{name} false" if ok == false }

      return 1 if matches.any? || pass_fail.include?(false)

      0
    end

    def build_notes(docs, absent, gates)
      notes = {}
      notes["engine"] = engine_version
      notes["absent_vintages"] = absent unless absent.empty?
      degenerate = docs.select { |_k, v| v == :degenerate }.keys
      notes["degenerate_vintages"] = degenerate unless degenerate.empty?
      notes["g5"] = gates["G-5"] == :skipped ? "skipped (source repo / #2146 head absent)" : "evaluated"
      notes["g5_note"] = "callers converge here; #2146's new thin eps score 0 by deadband (§3.5)"
      notes
    end

    # --------------------------------------------------------------------------
    # Gates — pure functions over engine-emitted findings + the id-map index.
    # Semantics mirror the P3-V1 reference (probe/verify_engine_scores.py) so
    # P3-V2 can verify gate-set ↔ canon equality (C-2).
    # --------------------------------------------------------------------------
    module Gates
      module_function

      # Round-half-away-from-zero, clamp ±5 — the normative `band_of` (V16-F1).
      def band_of(x)
        s = x >= 0 ? 1 : -1
        b = s * (x.abs + 0.5).floor
        [[b.to_i, 5].min, -5].max
      end

      # Build a per-vintage bundle from engine findings + a GraphRebuild result.
      # @return [Hash, nil] nil when the score surface is absent / zero-scored
      def bundle(prefix, doc, rebuilt)
        reus = doc["reusability"]
        return nil if reus.nil? || reus.empty?

        scored = reus.select { |_nid, e| e.is_a?(Hash) && !e["score"].nil? }
        return nil if scored.empty?

        ident = rebuilt.id_index
        by_fs = {}
        reus.each_key { |nid| (fs = ident[nid]) && (by_fs[fs] = nid) }
        booth_ms = {}
        (doc.dig("scores", "reusability_compass", "toll_booths") || []).each do |tb|
          booth_ms[tb["node"]] = tb["mass_savings"]
        end
        graph = read_graph(rebuilt.graph_path)

        { sha: prefix, doc: doc, reus: reus, scored: scored, ident: ident,
          class_of: rebuilt.class_of, booth_ms: booth_ms, by_fs: by_fs, graph: graph }
      end

      def read_graph(path)
        YAML.safe_load(File.read(path, encoding: "UTF-8"))
      end

      def entry(bundle, file_sym)
        nid = bundle[:by_fs][file_sym]
        nid && bundle[:reus][nid]
      end

      # Fold each gate family to a single boolean (AND over applicable vintages).
      # A required-but-degenerate vintage forces its gates false ("no scored
      # nodes"); a fully-absent vintage set leaves the gate reliant on what IS
      # present. G-5 is evaluated separately (source-repo dependent).
      # @param docs [Hash{String => Hash|:degenerate}]
      # @return [Hash{String => Boolean}]
      def families(docs)
        healthy = docs.reject { |_k, v| v == :degenerate }
        any_degenerate = docs.value?(:degenerate)

        {
          "G-1a" => g1a(healthy, docs),
          "G-1b" => g1b(healthy, docs),
          "G-2" => per_vintage(healthy, docs, any_needed: VINTAGES) { |b| g2(b) },
          "G-3" => per_vintage(healthy, docs, any_needed: VINTAGES) { |b| g3(b) },
          "G-4" => per_vintage(healthy, docs, any_needed: VINTAGES) { |b| g4(b) },
          "G-8" => g8(healthy, docs),
          "G-10" => per_vintage(healthy, docs, any_needed: VINTAGES) { |b| g10(b) },
          "G-11" => g11(healthy, docs),
          "G-12" => per_vintage(healthy, docs, any_needed: VINTAGES) { |b| g12(b) },
          "G-13" => g13(healthy, docs),
          "G-14" => per_vintage(healthy, docs, any_needed: VINTAGES) { |b| g14(b) },
          "G-15" => per_vintage(healthy, docs, any_needed: VINTAGES) { |b| g15(b) }
        }
      end

      # Evaluate a per-vintage gate across every healthy vintage present; false if
      # any present vintage fails OR any needed vintage is degenerate.
      def per_vintage(healthy, docs, any_needed:)
        present = healthy.keys & any_needed
        return false if (docs.select { |_k, v| v == :degenerate }.keys & any_needed).any?
        return false if present.empty?

        present.all? { |k| yield healthy[k] }
      end

      # ---- G-1 monster level + delta ----
      def g1a(healthy, docs)
        return false if docs[Tier4::BASE] == :degenerate
        e = healthy[Tier4::BASE] && entry(healthy[Tier4::BASE], Tier4::MONSTER)
        return false if e.nil?

        exp = Tier4::MONSTER_ANCHOR[Tier4::BASE]
        e["score"] <= -4.0 && [e["score"], e["score_band"], e["score_raw"]] == exp
      end

      def g1b(healthy, docs)
        return false if docs[Tier4::BASE] == :degenerate || docs[Tier4::HEAD] == :degenerate

        eb = healthy[Tier4::BASE] && entry(healthy[Tier4::BASE], Tier4::MONSTER)
        eh = healthy[Tier4::HEAD] && entry(healthy[Tier4::HEAD], Tier4::MONSTER)
        return false if eb.nil? || eh.nil?

        eh["score_raw"] < eb["score_raw"] &&
          [eb["score_band"], eh["score_band"]] == [-4, -5] &&
          eh["score"] == Tier4::MONSTER_ANCHOR[Tier4::HEAD][0]
      end

      # ---- G-2 booths positive (ordering-invariant cohort, V16-F2) ----
      def g2(b)
        ms_list = b[:booth_ms].values.compact.sort.reverse
        return false if ms_list.size < 20

        floor = ms_list[19]
        return false unless floor == Tier4::MS_FLOOR[b[:sha]]

        cohort = b[:booth_ms].select { |_nid, ms| ms && ms >= floor }.keys
        all_pos = cohort.all? do |nid|
          s = b[:reus].dig(nid, "score")
          !s.nil? && s >= 3.0
        end
        top_ms = ms_list.first
        tied = b[:booth_ms].select { |_nid, ms| ms == top_ms }.keys
        r1 = tied.first
        e1 = b[:reus][r1] || {}
        all_pos && top_ms == 32 && tied.size == 1 &&
          b[:ident][r1] == Tier4::RANK1 &&
          [e1["score"], e1["score_band"], e1["score_raw"]] == Tier4::RANK1_ANCHOR
      end

      # ---- G-3 pole exclusivity (observable recount) ----
      def g3(b)
        neg_booth = b[:scored].count { |_nid, e| e["score"] < 0 && e["toll_booth"] }
        pos_nonbooth = b[:scored].count { |_nid, e| e["score"] > 0 && !e["toll_booth"] }
        neg_booth.zero? && pos_nonbooth.zero?
      end

      # ---- G-4 distribution sanity (six band shares + internal consistency) ----
      def g4(b)
        sd = b[:doc].dig("scores", "reusability_compass", "score_distribution")
        return false if sd.nil?

        n = sd["n_scored"]
        bands = sd["bands"]
        return false if n.nil? || bands.nil? || n.zero?

        fold = Hash.new(0)
        b[:scored].each_value { |e| fold[e["score_band"].to_s] += 1 }
        share = ->(*keys) { 100.0 * keys.sum { |k| bands[k].to_i } / n }
        mode0 = share.call("0")
        le_m3 = share.call("-3", "-4", "-5")
        ge_p3 = share.call("3", "4", "5")
        le_m4 = share.call("-4", "-5")

        n == Tier4::EXPECTED_N[b[:sha]] && sd["n_null"] == 0 &&
          bands == Tier4::EXPECTED_HIST[b[:sha]] &&
          fold.select { |_k, v| v.positive? } == bands.select { |_k, v| v.positive? } &&
          mode0.between?(60.0, 80.0) && le_m3.between?(0.1, 2.0) &&
          ge_p3.between?(1.0, 5.0) && le_m4 <= 0.5 &&
          share.call("-5") <= 0.5 && share.call("5") <= 0.5
      end

      # ---- G-8 churn: unchanged-tuple movers == 0 per consecutive pair (V16-F18) ----
      def g8(healthy, docs)
        churn_pairs(healthy, docs) do |da, db, fs|
          ea = da[:reus][da[:by_fs][fs]]
          eb = db[:reus][db[:by_fs][fs]]
          ta = tuple(da, ea, da[:by_fs][fs])
          tb = tuple(db, eb, db[:by_fs][fs])
          next true unless ta == tb # only unchanged-tuple nodes constrain

          [ea["score"], ea["score_band"], ea["score_raw"]] ==
            [eb["score"], eb["score_band"], eb["score_raw"]]
        end
      end

      def tuple(bundle, e, nid)
        [e["collapse"], e["blast"], e["toll_booth"], !!e["escape"], bundle[:booth_ms][nid]]
      end

      # ---- G-10 escapes negative (findings key `escape`, singular — V16-F9) ----
      def g10(b)
        esc = b[:reus].select { |_nid, e| e.is_a?(Hash) && e["escape"] }
        esc_scored = esc.select { |_nid, e| !e["score"].nil? }
        return false if esc_scored.empty?

        all_neg = esc_scored.all? { |_nid, e| e["score"] < 0 }
        return all_neg unless [Tier4::BASE, Tier4::HEAD].include?(b[:sha])

        we = entry(b, Tier4::WORST_ESCAPE)
        all_neg && esc_scored.size == 13 && !we.nil? &&
          [we["score"], we["score_band"], we["score_raw"]] == Tier4::WORST_ESCAPE_ANCHOR
      end

      # ---- G-11 per-class signed-extremes block (monster class, head) ----
      def g11(healthy, docs)
        return false if docs[Tier4::HEAD] == :degenerate

        b = healthy[Tier4::HEAD]
        return false if b.nil?

        byc = b[:doc]["reusability_by_class"]
        return false if byc.nil? || byc.empty?

        nid = b[:by_fs][Tier4::MONSTER]
        cls = nid && b[:class_of][nid]
        row = cls && byc[cls]
        return false if row.nil?

        norm = row.slice(*Tier4::MONSTER_CLASS_ROW.keys)
        rank = 1 + byc.count { |_c, r| r["min"] < row["min"] }
        n_at_min = byc.count { |_c, r| r["min"] == row["min"] }
        byc.size == Tier4::CLASS_COUNT_HEAD && norm == Tier4::MONSTER_CLASS_ROW &&
          row["headline"] == row["min"] && rank == 1 && n_at_min == 1
      end

      # ---- G-12 absorb exclusivity (monster/escapes/collapse>2 → absorb ABSENT) ----
      def g12(b)
        leaks = b[:reus].count do |_nid, e|
          next false unless e.is_a?(Hash) && e.key?("absorb")

          c = e["collapse"]
          e["escape"] || (!c.nil? && c > 2)
        end
        monster = entry(b, Tier4::MONSTER)
        monster_clean = monster.nil? || (!monster.key?("absorb") && !monster.key?("absorb_raw"))
        leaks.zero? && monster_clean
      end

      # ---- G-13 absorb churn-free across consecutive vintages ----
      def g13(healthy, docs)
        # BASE→MID, MID→HEAD (the L9-A consecutive-pair lock)
        pairs = [[Tier4::BASE, Tier4::MID], [Tier4::MID, Tier4::HEAD]]
        applicable = pairs.select { |a, c| healthy.key?(a) && healthy.key?(c) }
        return false if applicable.empty?
        return false if docs.value?(:degenerate)

        applicable.all? do |a, c|
          da = healthy[a]
          db = healthy[c]
          common = da[:by_fs].keys & db[:by_fs].keys
          common.all? do |fs|
            ea = da[:reus][da[:by_fs][fs]]
            eb = db[:reus][db[:by_fs][fs]]
            ba = ea.key?("absorb") ? band_of(ea["absorb"]) : nil
            bb = eb.key?("absorb") ? band_of(eb["absorb"]) : nil
            ba == bb
          end
        end
      end

      # ---- G-14 absorb distribution envelope ----
      def g14(b)
        n = b[:scored].size
        absorb = b[:reus].values.select { |e| e.is_a?(Hash) && e.key?("absorb") }
                        .map { |e| e["absorb"] }
        return false if n.zero?

        eligible = 100.0 * absorb.size / n
        ge3 = 100.0 * absorb.count { |a| band_of(a) >= 3 } / n
        p5 = 100.0 * absorb.count { |a| band_of(a) >= 5 } / n
        eligible.between?(10.0, 35.0) && ge3.between?(1.0, 5.0) && p5 <= 0.5
      end

      # ---- G-15 zero-pred entrypoints carry no absorb ----
      def g15(b)
        graph = b[:graph]
        return false if graph.nil?

        has_pred = (graph["edges"] || []).map { |e| e["to"] }.to_set
        zero_pred = (graph["entrypoints"] || []).reject { |nid| has_pred.include?(nid) }
        zero_pred.none? { |nid| (b[:reus][nid] || {}).key?("absorb") }
      end

      # Shared: fold a boolean sub-check over the consecutive vintage pairs.
      def churn_pairs(healthy, docs)
        return false if docs.value?(:degenerate)

        pairs = [[Tier4::BASE, Tier4::MID], [Tier4::MID, Tier4::HEAD], [Tier4::HEAD, Tier4::TWOMO]]
        applicable = pairs.select { |a, c| healthy.key?(a) && healthy.key?(c) }
        return false if applicable.empty?

        applicable.all? do |a, c|
          da = healthy[a]
          db = healthy[c]
          common = da[:by_fs].keys & db[:by_fs].keys
          common.all? { |fs| yield da, db, fs }
        end
      end
    end
  end

  CLI.register_tier("4", lambda do |corpus:, opts:|
    Tier4.run(corpus: corpus, opts: opts)
  end)
end
