# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

# THE DECLARED BOUNDARY (configurator W4 / C9) — resolver tier R1.5.
#
# W2 was a data move proven by byte-identity; W3 was an inert tag proven by a
# zero count change. THIS is the first REAL behaviour change in the configurator
# arc: a declared boundary makes the collector STOP where the profile says to
# stop. No invariant proves that for free, so every claim below is anchored on a
# fixture whose two directions DISAGREE — a fixture that could only be satisfied
# by the right implementation.
#
# WHY THE FIXTURE HAS TWO VERBS. `Payments::Gateway` carries a CLASS rule
# (category `gem`) and a CALL rule (`charge` only, category `http`). A one-verb
# fixture cannot tell "most-specific-wins" from "declaration-order-wins" from
# "the call rule shadows the whole class" — all three produce the same single
# answer. With two verbs the three implementations produce three different
# answers, and only one of them is the specified one.
#
# EVERY SOURCE HERE IS SYNTHETIC AND PUBLIC (L9): no analysed-repo data, no
# developer paths, no repository names.
RSpec.describe "declared boundary (R1.5)" do
  RB       = Archbuddy::Collect::Adapters::Ruby unless defined?(RB)
  CONTRACT = ArchitectureAuditor::Contract unless defined?(CONTRACT)

  # --- the corpus --------------------------------------------------------

  # Two verbs on ONE in-tree constant — the disagreement fixture.
  GATEWAY_FILES = {
    "app/payments/gateway.rb" => <<~RUBY,
      module Payments
        class Gateway
          def self.charge(amount)
            amount
          end

          def self.refund(amount)
            amount
          end
        end
      end
    RUBY
    "app/services/checkout.rb" => <<~RUBY
      class Checkout
        def call
          Payments::Gateway.charge(1)
          Payments::Gateway.refund(2)
        end
      end
    RUBY
  }.freeze

  # An in-tree ancestry pair + a non-ignored "third party" subtree + a subtree
  # the SCAN-TIME ignore veto removes before any boundary rule can see it.
  ANCESTRY_FILES = {
    "app/adapters/base_adapter.rb" => <<~RUBY,
      class BaseAdapter
        def self.ping
          :base
        end
      end
    RUBY
    "app/adapters/legacy_adapter.rb" => <<~RUBY,
      class LegacyAdapter < BaseAdapter
        def self.ping
          :legacy
        end
      end
    RUBY
    "lib/third_party/bundled_client.rb" => <<~RUBY,
      class BundledClient
        def self.ping
          :bundled
        end
      end
    RUBY
    "vendor/ignored_client.rb" => <<~RUBY,
      class IgnoredClient
        def self.ping
          :ignored
        end
      end
    RUBY
    "app/services/caller.rb" => <<~RUBY
      class Caller
        def call
          BaseAdapter.ping
          LegacyAdapter.ping
          BundledClient.ping
          IgnoredClient.ping
        end
      end
    RUBY
  }.freeze

  CLASS_RULE = {
    "kind" => "constant_exact", "values" => ["Payments::Gateway"], "category" => "gem"
  }.freeze

  CALL_RULE = {
    "receiver" => { "kind" => "constant_exact", "values" => ["Payments::Gateway"] },
    "verbs" => ["charge"], "category" => "http", "role" => "action"
  }.freeze

  # --- plumbing ----------------------------------------------------------

  # The shipped document with a boundary section injected. DERIVED FROM THE
  # PRODUCER: everything except `boundary` is whatever the engine actually
  # serves, so a fixture can never drift into asserting against a profile the
  # engine would not hand back.
  def document_with(boundary)
    doc = JSON.parse(JSON.generate(RB::Profile::Profiles.load(RB::Profile::DEFAULT_ID)))
    boundary.nil? ? doc.tap { |d| d.delete("boundary") } : doc.tap { |d| d["boundary"] = boundary }
  end

  def profile_with(boundary)
    RB::Profile.new(document_with(boundary))
  end

  def collect(boundary, files)
    profile = profile_with(boundary)
    allow(RB::Profile).to receive(:for).and_return(profile)

    Dir.mktmpdir("archbuddy-boundary") do |dir|
      files.each do |name, source|
        path = File.join(dir, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      config = Archbuddy::Collect::Config.new(language: "ruby", probes: :all)
      Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
    end
  end

  def sinks(result)
    result.nodes.select { |node| node.kind.to_s == "external" }.map(&:symbol).sort
  end

  def edge_pairs(result)
    symbol_of = result.nodes.to_h { |node| [node.real_key, node.symbol] }
    result.edges.map { |edge| [symbol_of[edge.from_key], symbol_of[edge.to_key]] }.sort
  end

  def sink_named(result, symbol)
    result.nodes.find { |node| node.symbol == symbol }
  end

  # =====================================================================
  # THE FIXTURE IS LEGAL, AND THE ARMS REALLY DIFFER
  # =====================================================================
  describe "fixture legality (no assertion below rests on an illegal profile)" do
    it "every boundary document used here validates against the ENGINE's profile schema" do
      [nil, {}, { "paths" => [], "classes" => [], "calls" => [] },
       { "classes" => [CLASS_RULE], "calls" => [CALL_RULE] }].each do |boundary|
        expect(CONTRACT::Validator.valid?(:profile, document_with(boundary))).to be(true),
                                                                                "boundary #{boundary.inspect} is not a legal profile"
      end
    end

    it "the SHIPPED reference profile declares the section with every list EMPTY — opt-in by construction" do
      # If this ever ships non-empty, every byte-identity claim in the suite is
      # silently measuring something else.
      expect(RB::Profile.reference.boundary).to eq("paths" => [], "classes" => [], "calls" => [])
      expect(RB::BoundaryRules.for_profile(RB::Profile.reference).declared?).to be(false)
    end
  end

  # =====================================================================
  # PRECEDENCE — where a wrong implementation hides
  # =====================================================================
  describe "most-specific-wins: call > class > path" do
    let(:result) { collect({ "classes" => [CLASS_RULE], "calls" => [CALL_RULE] }, GATEWAY_FILES) }

    it "the call rule wins on `charge` — NOT the class rule, NOT declaration order" do
      # A least-specific-wins implementation yields `gem` here.
      # A declaration-order-wins implementation yields whichever list came first.
      expect(sink_named(result, "<external:http:Payments::Gateway>")).not_to be_nil
      expect(sink_named(result, "<external:http:Payments::Gateway>").terminal_kind).to eq("http")
    end

    it "the class rule still owns `refund` — a call rule does NOT shadow the whole class" do
      # The variant where a matched call rule claims every verb on that receiver
      # leaves `refund` at the generic sink and this fails.
      expect(sink_named(result, "<external:gem:Payments::Gateway>")).not_to be_nil
      expect(sink_named(result, "<external:gem:Payments::Gateway>").terminal_kind).to eq("gem")
    end

    it "THE TWO DIRECTIONS DISAGREE ON ONE FIXTURE — both crossings exist, with DIFFERENT categories" do
      expect(sinks(result)).to eq(
        ["<external:gem:Payments::Gateway>", "<external:http:Payments::Gateway>", "<external>"]
      )
      expect(edge_pairs(result)).to eq(
        [["Checkout#call", "<external:gem:Payments::Gateway>"],
         ["Checkout#call", "<external:http:Payments::Gateway>"]]
      )
    end

    it "with the CLASS rule removed, `refund` resolves to a REAL EDGE — severing is never unconditional" do
      # Rules out the implementation that severs the receiver as soon as ANY
      # rule mentions it.
      call_only = collect({ "calls" => [CALL_RULE] }, GATEWAY_FILES)

      expect(edge_pairs(call_only)).to eq(
        [["Checkout#call", "<external:http:Payments::Gateway>"],
         ["Checkout#call", "Payments::Gateway.refund"]]
      )
    end
  end

  # =====================================================================
  # A DECLARATION BEATS AN INFERENCE (the R1.5 placement itself)
  # =====================================================================
  describe "R1.5 sits ABOVE the in-tree inference tiers" do
    it "SEVERS the real R4 edge it would otherwise have resolved" do
      # The control: with no rules the SAME source yields two in-tree edges.
      without = collect({}, GATEWAY_FILES)
      expect(edge_pairs(without)).to eq(
        [["Checkout#call", "Payments::Gateway.charge"],
         ["Checkout#call", "Payments::Gateway.refund"]]
      )

      with = collect({ "classes" => [CLASS_RULE] }, GATEWAY_FILES)
      expect(edge_pairs(with)).to eq(
        [["Checkout#call", "<external:gem:Payments::Gateway>"],
         ["Checkout#call", "<external:gem:Payments::Gateway>"]].uniq
      )
    end

    it "the severed methods still EXIST as nodes — a black box is O(1) from outside, not deleted" do
      with = collect({ "classes" => [CLASS_RULE] }, GATEWAY_FILES)

      expect(with.nodes.map(&:symbol)).to include("Payments::Gateway.charge", "Payments::Gateway.refund")
      expect(edge_pairs(with).map(&:last)).not_to include("Payments::Gateway.charge")
    end

    it "R1.5 IS NOT A PROBE — a declared crossing never appears in probe_edges" do
      # An implementation that registered the boundary as an R5 probe would (a)
      # tally here and (b) be unable to override an in-tree edge at all.
      with = collect({ "classes" => [CLASS_RULE], "calls" => [CALL_RULE] }, GATEWAY_FILES)

      expect(with.diagnostics[:probe_edges]).to eq({})
      expect(with.diagnostics[:egress_counts]).to eq({ gem: 1, http: 1 }) # positive control: it DID fire
    end

    it "an implicit-self call can never be claimed — a boundary is crossed, not inhabited" do
      files = {
        "app/services/gateway.rb" => <<~RUBY
          class Gateway
            def call
              charge
            end

            def charge
              :ok
            end
          end
        RUBY
      }
      boundary = { "classes" => [{ "kind" => "constant_exact", "values" => ["Gateway"], "category" => "gem" }] }

      expect(edge_pairs(collect(boundary, files))).to eq([%w[Gateway#call Gateway#charge]])
    end
  end

  # =====================================================================
  # THE THREE GRANULARITIES
  # =====================================================================
  describe "class rules match IDENTITY or ANCESTRY, never AST shape" do
    it "`ancestor_of` claims the subclass and NOT the named ancestor itself" do
      boundary = { "classes" => [{ "kind" => "ancestor_of", "values" => ["BaseAdapter"], "category" => "gem" }] }
      result   = collect(boundary, ANCESTRY_FILES)

      # LegacyAdapter < BaseAdapter is severed; BaseAdapter itself is NOT
      # (self-identity is not ancestry — that is what constant_exact is for).
      expect(edge_pairs(result)).to include(["Caller#call", "<external:gem:LegacyAdapter>"])
      expect(edge_pairs(result)).to include(%w[Caller#call BaseAdapter.ping])
    end

    it "`constant_prefix` claims every constant under a namespace" do
      boundary = { "classes" => [{ "kind" => "constant_prefix", "values" => ["Payments::"], "category" => "gem" }] }

      expect(sinks(collect(boundary, GATEWAY_FILES))).to include("<external:gem:Payments::Gateway>")
    end

    it "THE MIDDLEWARE HAZARD IS STRUCTURALLY INEXPRESSIBLE — the match vocabulary has no shape option" do
      # Read from the PRODUCER (the engine's profile schema), never re-typed.
      # Owner code shaped like framework code cannot be caught by a class rule,
      # because there is no kind in which "has this method shape" can be written.
      kinds = JSON.parse(File.read(CONTRACT::Validator.schema_path(:profile)))
                  .fetch("definitions").fetch("constant_match_kind").fetch("enum")

      expect(kinds).to eq(%w[constant_exact constant_prefix ancestor_of])
      expect(kinds.grep(/shape|arity|ivar|param|block|call_env/)).to eq([])
    end
  end

  describe "path rules match the TARGET's definition site, not the caller's" do
    it "claims a call INTO the globbed subtree, from a caller outside it" do
      boundary = { "paths" => [{ "glob" => "lib/third_party/**", "category" => "gem" }] }
      result   = collect(boundary, ANCESTRY_FILES)

      # The caller lives in app/services — if the rule matched the CALLER's path
      # this crossing would not exist and the other three would.
      expect(edge_pairs(result)).to include(["Caller#call", "<external:gem:BundledClient>"])
      expect(edge_pairs(result)).to include(%w[Caller#call BaseAdapter.ping])
    end

    it "path ordering is LONGEST LITERAL PREFIX, never declaration order" do
      # Declared least-specific FIRST; the more specific glob must still win.
      boundary = {
        "paths" => [{ "glob" => "lib/**", "category" => "queue" },
                    { "glob" => "lib/third_party/**", "category" => "gem" }]
      }
      result = collect(boundary, ANCESTRY_FILES)

      expect(sink_named(result, "<external:gem:BundledClient>")).not_to be_nil
      expect(sink_named(result, "<external:queue:BundledClient>")).to be_nil
    end
  end

  describe "the call rule is the ONLY granularity that may carry a role" do
    it "the declared role rides onto the declared crossing's sink" do
      result = collect({ "classes" => [CLASS_RULE], "calls" => [CALL_RULE] }, GATEWAY_FILES)

      expect(sink_named(result, "<external:http:Payments::Gateway>").cco_role).to eq("action")
    end

    it "a class rule's sink carries NO role — ABSENT, never defaulted" do
      result = collect({ "classes" => [CLASS_RULE], "calls" => [CALL_RULE] }, GATEWAY_FILES)

      expect(sink_named(result, "<external:gem:Payments::Gateway>").cco_role).to be_nil
    end

    it "the restriction is STRUCTURAL: a class rule carrying a role is schema-INVALID" do
      # Not an assertion a loader has to remember to make.
      roled_class = CLASS_RULE.merge("role" => "action")

      expect(CONTRACT::Validator.valid?(:profile, document_with("classes" => [roled_class]))).to be(false)
      expect(CONTRACT::Validator.valid?(:profile, document_with("classes" => [CLASS_RULE]))).to be(true)
    end
  end

  # =====================================================================
  # LOUD, NEVER SILENT
  # =====================================================================
  describe "load-time guards" do
    it "a category outside the closed vocabulary RAISES, naming the allowed set read from the PRODUCER" do
      bad = { "classes" => [CLASS_RULE.merge("category" => "database")] }

      expect { RB::BoundaryRules.for_profile(profile_with(bad)) }
        .to raise_error(RB::BoundaryRules::UnknownCategoryError, /"database".*#{Regexp.escape(CONTRACT::TERMINAL_KINDS.inspect)}/m)
    end

    it "POSITIVE CONTROL: every member of the producer constant is accepted" do
      # Without this, the guard above could be raising on everything.
      CONTRACT::TERMINAL_KINDS.each do |category|
        expect { RB::BoundaryRules.for_profile(profile_with("classes" => [CLASS_RULE.merge("category" => category)])) }
          .not_to raise_error
      end
    end

    it "the closed vocabulary is READ, never re-typed" do
      expect(RB::BoundaryRules.allowed_categories).to equal(CONTRACT::TERMINAL_KINDS)
    end

    it "a duplicate rule of the same granularity is a HARD ERROR, never resolved by declaration order" do
      duplicate = { "classes" => [CLASS_RULE, CLASS_RULE.merge("category" => "http")] }

      expect { RB::BoundaryRules.for_profile(profile_with(duplicate)) }
        .to raise_error(RB::BoundaryRules::DuplicateRuleError, /classes/)
    end

    it "duplicate detection is ORDER-INSENSITIVE on the values list" do
      a = { "kind" => "constant_exact", "values" => %w[A B], "category" => "gem" }
      b = { "kind" => "constant_exact", "values" => %w[B A], "category" => "http" }

      expect { RB::BoundaryRules.for_profile(profile_with("classes" => [a, b])) }
        .to raise_error(RB::BoundaryRules::DuplicateRuleError)
    end

    it "NEGATIVE CONTROL: two rules differing only in KIND are not duplicates" do
      a = { "kind" => "constant_exact",  "values" => ["A"], "category" => "gem" }
      b = { "kind" => "constant_prefix", "values" => ["A"], "category" => "http" }

      expect { RB::BoundaryRules.for_profile(profile_with("classes" => [a, b])) }.not_to raise_error
    end
  end

  # =====================================================================
  # DEGENERATE — the GATE × POPULATION cross product
  # =====================================================================
  describe "degenerate: gate × population" do
    it "NO boundary section at all ⇒ the tier short-circuits before compiling anything" do
      # ABSENT is a distinct state from empty and is reported as such: nil, not
      # a fabricated {}.
      profile = profile_with(nil)

      expect(profile.boundary).to be_nil
      expect(RB::BoundaryRules.for_profile(profile)).to be_nil
      expect(RB::BoundaryRules.resolve(:no_ctx_needed, profile)).to be_nil
    end

    it "a section present with every list EMPTY compiles a REAL but undeclared index" do
      # Distinguishable from absent — an empty declaration is a declaration of
      # nothing, not the absence of a declaration.
      index = RB::BoundaryRules.for_profile(profile_with("paths" => [], "classes" => [], "calls" => []))

      expect(index).not_to be_nil
      expect(index.declared?).to be(false)
    end

    it "ZERO RULES ⇒ the emitted graph is IDENTICAL to the no-section arm — the opt-in proof" do
      absent = collect(nil, GATEWAY_FILES)
      empty  = collect({ "paths" => [], "classes" => [], "calls" => [] }, GATEWAY_FILES)

      expect(sinks(empty)).to eq(sinks(absent))
      expect(edge_pairs(empty)).to eq(edge_pairs(absent))
      expect(sinks(empty)).to eq(["<external>"]) # non-vacuity: the arms are not both junk
    end

    it "rules present, ZERO matching call sites ⇒ ZERO sinks minted (never-fabricate)" do
      # An implementation that mints a sink per declared rule fails here.
      unmatched = collect({ "classes" => [{ "kind" => "constant_exact", "values" => ["Nope::Missing"], "category" => "gem" }] },
                          GATEWAY_FILES)

      expect(sinks(unmatched)).to eq(["<external>"])
      expect(unmatched.diagnostics[:egress_counts]).to eq({})
    end

    it "rules present, matches SCAN-TIME IGNORED ⇒ the rule contributes NOTHING; the veto still runs FIRST" do
      # `vendor/` is in Collect::Config::DEFAULT_IGNORE, so the file is never
      # parsed and the constant never enters the table — a PATH rule keyed on
      # the target's definition site therefore cannot see it. The boundary is
      # layered ON TOP of the veto, never replacing it, and the veto wins.
      #
      # This is the cell otherwise indistinguishable from a typo, so it is
      # asserted as a DIFFERENCE against the no-rules arm, not in isolation:
      # the emitted graph must be identical either way.
      boundary = { "paths" => [{ "glob" => "vendor/**", "category" => "gem" }] }
      with     = collect(boundary, ANCESTRY_FILES)
      without  = collect({}, ANCESTRY_FILES)

      expect(Archbuddy::Collect::Config::DEFAULT_IGNORE).to include("vendor")
      expect(sinks(with)).to eq(sinks(without))
      expect(edge_pairs(with)).to eq(edge_pairs(without))

      # The call site is still honestly accounted for — but by the EgressProbe
      # at R5 (IgnoredClient is out-of-tree), NOT by the declared boundary. The
      # positive control that keeps the equality above from being vacuous.
      expect(edge_pairs(without)).to include(["Caller#call", "<external:gem:IgnoredClient>"])
    end

    it "a rule with NO category ⇒ the generic sink and NO terminal_kind — ABSENT, never a plausible default" do
      boundary = { "classes" => [{ "kind" => "constant_exact", "values" => ["Payments::Gateway"] }] }
      result   = collect(boundary, GATEWAY_FILES)

      expect(sinks(result)).to eq(["<external>"])
      expect(sink_named(result, "<external>").terminal_kind).to be_nil
      # It still SEVERED — the crossing is real, only its category is undeclared.
      expect(edge_pairs(result)).to eq([%w[Checkout#call <external>]])
    end
  end
end
