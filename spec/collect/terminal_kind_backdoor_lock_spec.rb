# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "tempfile"
require "stringio"
require "architecture_auditor/cli"

# THE A6 BACK-DOOR LOCK — CLIENT HALF (configurator W4 / C12).
#
# A6 names two back doors by which a CLASSIFICATION-ONLY tag can quietly become
# a scoring input. Neither works by value; both work by PRESENCE:
#
#   1. `terminal_kind`'s MERE NON-NIL PRESENCE gates seed-set membership for the
#      graded egress dimension. A node that acquires the key acquires a score
#      contribution, whatever the key says.
#   2. the closed `kind` enum has the same presence effect through node
#      population.
#
# W4 is exactly where this matters, because W4 is the wave in which a
# DECLARATION MINTS A SINK. A boundary crossing adds a node; adding nodes is how
# a classification silently moves a number.
#
# The ENGINE half already ships (spec/analyze/cco_role_backdoor_lock_spec.rb:
# `cco_role` appears nowhere under analyze/, and stamping every node with every
# role leaves the findings byte-identical). THIS IS THE CLIENT HALF: the three
# invariants that keep the client from ever HANDING the engine a document in
# which the back doors are open, each derived from its PRODUCER, none re-typing
# a vocabulary.
#
# WHY EVERY INVARIANT IS ALSO SHOWN FAILING. A back-door guard that cannot fire
# guards nothing, and there is no way to tell a working guard from a vacuous one
# by reading it. Each invariant below is a PREDICATE, asserted empty on the real
# capture and NON-empty on a document mutated to open the door it locks.
#
# Every source here is SYNTHETIC and PUBLIC (L9).
RSpec.describe "the A6 back doors are locked (client half)" do
  RUBY_NS  = Archbuddy::Collect::Adapters::Ruby unless defined?(RUBY_NS)
  CONTRACT = ArchitectureAuditor::Contract unless defined?(CONTRACT)

  # A crossing sink's real-space symbol. The ONE spelling of "this node is a
  # proven crossing", and the discriminator invariant 1 is stated against.
  CROSSING_SYMBOL = /\A<external:[^:]+:/
  # The ANALYSIS BOUNDARY minted for an unresolved call: one per (caller, name),
  # never shared. It is a TERMINAL but explicitly NOT a proven crossing.
  BOUNDARY_SYMBOL = /\A<boundary:unknown:/
  # Either kind of terminal — the population that legitimately carries a
  # terminal_kind at all.
  TERMINAL_SYMBOL = /\A<(external:[^:]+|boundary:unknown):/

  # ONE fixture carrying EVERY state at once, because each invariant is an "iff"
  # and an iff over a single-state population is satisfied vacuously on one side.
  # In one run this produces: entrypoints, plain functions, roled db_ops, the
  # generic (categoryless) external sink, and FOUR crossing sinks spanning http,
  # gem, queue AND a PROFILE-DECLARED crossing.
  C12_FILES = {
    "app/models/invoice.rb" => "class Invoice < ApplicationRecord\nend\n",
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
    "app/controllers/checkout_controller.rb" => <<~RUBY
      class CheckoutController < ApplicationController
        def create
          Invoice.create!(amount: 1)
          Invoice.count
          Payments::Gateway.charge(1)
          Payments::Gateway.refund(2)
          Faraday.get("/x")
          SomeGem.configure
          OutOfTreeWorker.perform_async(1)
          mystery.call_it
        end

        def mystery
          Object
        end
      end
    RUBY
  }.freeze

  # The declared crossing: `charge` only, so `refund` stays a real in-tree edge
  # and the fixture carries both sides of the severing consequence.
  DECLARED_CALL_RULE = {
    "receiver" => { "kind" => "constant_exact", "values" => ["Payments::Gateway"] },
    "verbs" => ["charge"], "category" => "http", "role" => "action"
  }.freeze

  # --- capture plumbing ---------------------------------------------------

  def document_with(boundary)
    doc = JSON.parse(JSON.generate(RUBY_NS::Profile::Profiles.load(RUBY_NS::Profile::DEFAULT_ID)))
    doc["boundary"] = boundary
    doc
  end

  def capture(boundary: { "paths" => [], "classes" => [], "calls" => [DECLARED_CALL_RULE] })
    allow(RUBY_NS::Profile).to receive(:for).and_return(RUBY_NS::Profile.new(document_with(boundary)))

    Dir.mktmpdir("archbuddy-c12") do |dir|
      C12_FILES.each do |name, source|
        path = File.join(dir, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      config = Archbuddy::Collect::Config.new(language: "ruby", probes: :all)
      raw    = Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
      Archbuddy::Collect::Anonymizer.new(raw, tool: "archbuddy c12", adapter: "ruby").call
    end
  end

  let(:captured) { capture }
  let(:graph)    { captured.graph }
  let(:id_map)   { captured.id_map }

  def symbol_of(id_map, node_id)
    id_map.fetch("ids").fetch(node_id).fetch("symbol")
  end

  def nodes_with(doc, id_map)
    doc.fetch("nodes").map { |node| [node, symbol_of(id_map, node.fetch("id"))] }
  end

  def deep_dup(doc)
    Marshal.load(Marshal.dump(doc))
  end

  # =====================================================================
  # NON-DEGENERACY — asserted BEFORE any invariant runs
  # =====================================================================
  describe "NON-DEGENERACY GUARD: the fixture contains at least one node of each state" do
    it "carries crossings, a categoryless sink, db_ops, plain functions and entrypoints — all at once" do
      states = nodes_with(graph, id_map).group_by do |node, symbol|
        if symbol.match?(CROSSING_SYMBOL) then :crossing
        elsif symbol.match?(BOUNDARY_SYMBOL) then :boundary
        elsif node.fetch("kind") == "external" then :generic_sink
        elsif node.fetch("kind") == "db_op" then :db_op
        elsif node.fetch("kind") == "endpoint" then :endpoint
        else :function
        end
      end

      # `generic_sink` is GONE by design — the single shared node it named was
      # replaced by per-(caller,name) boundaries, so the state it guarded no
      # longer exists and demanding it would be unsatisfiable.
      %i[crossing boundary db_op endpoint function].each do |state|
        expect(states.fetch(state, []).size).to be >= 1, "fixture has NO #{state} node — the iff below is vacuous"
      end

      # …and the crossings span the whole STATICALLY-PRODUCIBLE vocabulary plus
      # the declared one, in a single run.
      #
      # "exit" is deliberately excluded from this expectation rather than the
      # guard being loosened: it is emitted ONLY by the boot-reflection tier
      # (R3.5), which requires a booted application, and this fixture is a pure
      # static capture. A static-only fixture cannot produce it, so demanding it
      # here would be unsatisfiable rather than protective. Its production is
      # asserted in spec/reflect/, so the vocabulary stays fully covered.
      # `exit` alone stays excluded: it is emitted ONLY by the boot-reflection
      # tier, which a pure static fixture cannot reach. `unknown` IS reachable
      # statically — it is the analysis boundary an unresolved call mints — so it
      # belongs in the population this guard demands.
      static_vocabulary = CONTRACT::TERMINAL_KINDS - %w[exit]
      categories = (states.fetch(:crossing, []) + states.fetch(:boundary, []))
                   .map { |node, _| node.fetch("terminal_kind") }
      expect(categories.uniq.sort).to eq(static_vocabulary.sort)
      expect(states.fetch(:crossing).map { |_, symbol| symbol }).to include("<external:http:Payments::Gateway>")
    end

    it "the DECLARED crossing is the boundary's doing — it is absent without the rule" do
      # Otherwise the whole file could be measuring the EgressProbe.
      without = capture(boundary: { "paths" => [], "classes" => [], "calls" => [] })
      symbols = nodes_with(without.graph, without.id_map).map(&:last)

      expect(symbols).not_to include("<external:http:Payments::Gateway>")
      expect(symbols).to include("<external:http:Faraday>") # positive control: egress still fires
    end
  end

  # =====================================================================
  # INVARIANT 1 — terminal_kind PRESENCE ⟺ PROVEN CROSSING
  # =====================================================================
  describe "invariant 1: terminal_kind presence ⟺ a proven crossing" do
    # @return [Array<String>] one message per node whose presence disagrees with
    #   its symbol. Empty == locked.
    # REFORMULATED (v0.13-locality). The invariant was "presence <=> a proven
    # crossing". That was correct while the only stamped nodes were crossings.
    # It is now "presence <=> the node is a TERMINAL WE CLASSIFIED", because an
    # unresolved call also mints a terminal — the analysis boundary — and it too
    # must carry a word. The guard is not weakened: the epistemic distinction it
    # used to carry by PRESENCE is now carried by VALUE, and locked separately
    # (and more sharply) in #value_violations below.
    def presence_violations(doc, id_map)
      nodes_with(doc, id_map).filter_map do |node, symbol|
        terminal = symbol.match?(TERMINAL_SYMBOL)
        stamped  = node.key?("terminal_kind")
        next if terminal == stamped

        "#{symbol}: terminal=#{terminal} but terminal_kind #{stamped ? "PRESENT" : "ABSENT"}"
      end
    end

    # The NEW half of the guard: the WORD must match what the node actually is.
    # A proven crossing may never be labelled "unknown", and an analysis boundary
    # may never claim one of the proven-channel words — that would assert a
    # crossing we never established, which is the exact fabrication this file
    # exists to prevent.
    def value_violations(doc, id_map)
      nodes_with(doc, id_map).filter_map do |node, symbol|
        tk = node["terminal_kind"]
        next if tk.nil?

        if symbol.match?(BOUNDARY_SYMBOL) && tk != "unknown"
          "#{symbol}: an analysis boundary claims the proven word #{tk.inspect}"
        elsif symbol.match?(CROSSING_SYMBOL) && tk == "unknown"
          "#{symbol}: a proven crossing is labelled unknown"
        end
      end
    end

    # One sink per DISTINCT [category, target] pair, and every one of them the
    # target of a real edge. Rules out a sink minted for a rule that matched
    # nothing (the fabrication this whole wave is exposed to).
    def pair_violations(doc, id_map)
      crossings = nodes_with(doc, id_map).select { |_, symbol| symbol.match?(CROSSING_SYMBOL) }
      targeted  = doc.fetch("edges").map { |edge| edge.fetch("to") }.to_set
      pairs     = crossings.map { |_, symbol| symbol.delete_prefix("<external:").delete_suffix(">").split(":", 2) }

      violations = []
      violations << "duplicate [category,target] sinks: #{pairs.tally.select { |_, n| n > 1 }.keys.inspect}" \
        if pairs.uniq.size != pairs.size
      crossings.each do |node, symbol|
        violations << "#{symbol}: minted but no inbound edge" unless targeted.include?(node.fetch("id"))
        category = symbol.delete_prefix("<external:").split(":", 2).first
        violations << "#{symbol}: terminal_kind #{node["terminal_kind"].inspect} is not the symbol's category" \
          unless node["terminal_kind"] == category
      end
      violations
    end

    it "LOCKED: every crossing is stamped and NOTHING else is" do
      expect(presence_violations(graph, id_map)).to eq([])
      # and the word must match what the node IS (v0.13-locality)
      expect(value_violations(graph, id_map)).to eq([])
    end

    it "LOCKED: one sink per distinct [category, target] pair, each with a real inbound edge" do
      expect(pair_violations(graph, id_map)).to eq([])
    end

    it "M-26 CONTROL — stamping a NON-CROSSING sink makes the iff FIRE" do
      # The mutation A6 door 1 describes, applied to the emitted document.
      # RE-TARGETED (v0.13-locality). This used to stamp the shared `<external>`
      # sink, which no longer exists — and a BOUNDARY sink now legitimately
      # carries a word, so it is no longer a valid control either. The node that
      # must NEVER carry one is a plain in-app function: stamping it asserts a
      # terminal where execution plainly continues.
      mutated = deep_dup(graph)
      fn = mutated.fetch("nodes").find { |n| n.fetch("kind") == "function" }
      fn["terminal_kind"] = "gem"

      expect(presence_violations(mutated, id_map)).to include(/terminal=false but terminal_kind PRESENT/)
    end

    it "M-26 CONTROL — un-stamping a REAL crossing also makes it FIRE (both directions)" do
      mutated = deep_dup(graph)
      mutated.fetch("nodes").find { |n| symbol_of(id_map, n["id"]) == "<external:gem:SomeGem>" }.delete("terminal_kind")

      expect(presence_violations(mutated, id_map)).to include(/SomeGem.*ABSENT/)
    end

    it "M-26 CONTROL — a sink minted with NO inbound edge makes the pair check FIRE" do
      mutated = deep_dup(graph)
      phantom_id = mutated.fetch("nodes").first.fetch("id").sub(/.\z/) { |c| c == "0" ? "1" : "0" }
      mutated["nodes"] << { "id" => phantom_id, "kind" => "external", "terminal_kind" => "gem" }
      phantom_map = deep_dup(id_map)
      phantom_map["ids"][phantom_id] = { "symbol" => "<external:gem:NeverCalled>" }

      expect(pair_violations(mutated, phantom_map)).to include(/NeverCalled>: minted but no inbound edge/)
    end

    it "THE DOOR IS REAL: the terminal_kind VALUE genuinely moves a published number" do
      # RESTATED (v0.13-locality). This proved that PRESENCE opens a door, which
      # was the right claim while only crossings were stamped. Now every terminal
      # carries a word, so presence no longer discriminates — and stamping a
      # non-terminal moves nothing, because the engine seeds egress only from
      # out-degree-0 nodes. The door that now matters is the VALUE: relabelling an
      # analysis boundary as a proven channel must move a number, or invariant 2
      # would be guarding a door that does not open.
      mutated = deep_dup(graph)
      boundary = mutated.fetch("nodes").find { |n| n["terminal_kind"] == "unknown" }
      expect(boundary).not_to be_nil # non-vacuity: the fixture really mints one
      boundary["terminal_kind"] = "gem"

      expect(CONTRACT::Validator.valid?(:graph, mutated)).to be(true) # the SCHEMA permits it
      expect(findings_bytes(mutated)).not_to eq(findings_bytes(graph)) # the SPEC is the guard
    end
  end

  # =====================================================================
  # INVARIANT 2 — the value space is CLOSED
  # =====================================================================
  describe "invariant 2: terminal_kind values come only from the producer constant" do
    def vocabulary_violations(doc)
      doc.fetch("nodes").filter_map do |node|
        value = node["terminal_kind"]
        next if value.nil? || CONTRACT::TERMINAL_KINDS.include?(value)

        "terminal_kind #{value.inspect} is outside #{CONTRACT::TERMINAL_KINDS.inspect}"
      end
    end

    it "LOCKED: every stamped value is a member of Contract::TERMINAL_KINDS" do
      stamped = graph.fetch("nodes").filter_map { |n| n["terminal_kind"] }

      expect(stamped).not_to be_empty # non-vacuity
      expect(vocabulary_violations(graph)).to eq([])
    end

    it "THE GRAPH SCHEMA LEAVES THE FIELD OPEN — this spec is what closes it" do
      # Read from the producer schema, not asserted from memory.
      field = JSON.parse(File.read(CONTRACT::Validator.schema_path(:graph)))
                  .fetch("definitions").fetch("node").fetch("properties").fetch("terminal_kind")

      expect(field).not_to have_key("enum")
      # WIDENED ONCE, DELIBERATELY (v0.13-reflect): "exit" is the GENERIC egress
      # category for a crossing PROVEN by boot reflection (an application class's
      # method DEFINED inside a gem) whose channel is unknown. The invariant
      # "presence <=> a proven crossing" is UNCHANGED — "exit" remains forbidden
      # on the unresolved catch-all sink, which is "could not RESOLVE", not
      # "could not TYPE".
      expect(CONTRACT::TERMINAL_KINDS).to eq(%w[http queue gem exit unknown])
    end

    it "M-27 CONTROL — a category outside the constant makes it FIRE, naming the value" do
      mutated = deep_dup(graph)
      mutated.fetch("nodes").find { |n| n["terminal_kind"] == "gem" }["terminal_kind"] = "database"

      expect(CONTRACT::Validator.valid?(:graph, mutated)).to be(true) # the schema accepts it
      expect(vocabulary_violations(mutated))
        .to eq(['terminal_kind "database" is outside ["http", "queue", "gem", "exit", "unknown"]'])
    end

    it "the CLIENT cannot emit one either — the boundary loader refuses at load" do
      # The producer-side half of the same claim (C9's gate), asserted here so
      # the closure is end-to-end and not just a post-hoc document check.
      bad = { "classes" => [{ "kind" => "constant_exact", "values" => %w[X], "category" => "database" }] }

      expect { RUBY_NS::BoundaryRules.for_profile(RUBY_NS::Profile.new(document_with(bad))) }
        .to raise_error(RUBY_NS::BoundaryRules::UnknownCategoryError)
    end
  end

  # =====================================================================
  # INVARIANT 3 — `kind` is NEVER derived from a category or a role
  # =====================================================================
  describe "invariant 3: every minted sink is kind == \"external\", unconditionally" do
    def kind_violations(doc, id_map)
      nodes_with(doc, id_map).filter_map do |node, symbol|
        # BOTH minted terminal families: proven crossings (<external:...>) and
        # analysis boundaries (<boundary:unknown:...>). Both are kind "external";
        # the family is carried by the SYMBOL and the epistemics by terminal_kind,
        # never by inventing a kind.
        next unless symbol.start_with?("<external", "<boundary")
        next if node.fetch("kind") == "external"

        "#{symbol}: kind #{node.fetch("kind").inspect} — derived from a category or a role"
      end
    end

    it "LOCKED across http, gem, queue, a DECLARED crossing and an analysis boundary, in ONE run" do
      sinks = nodes_with(graph, id_map).select { |_, symbol| symbol.start_with?("<external", "<boundary") }

      expect(sinks.size).to be >= 5 # non-vacuity: all five states present
      expect(kind_violations(graph, id_map)).to eq([])
    end

    it "POSITIVE CONTROL: `kind` is not constant everywhere — db_op nodes carry their own" do
      # Without this, invariant 3 could hold because the client emits exactly
      # one kind for everything.
      kinds = graph.fetch("nodes").map { |n| n.fetch("kind") }.uniq.sort

      expect(kinds).to include("db_op", "external", "function", "endpoint")
    end

    it "an ACTION-roled crossing is still kind external — the role is not a 5th kind" do
      declared = nodes_with(graph, id_map).find { |_, s| s == "<external:http:Payments::Gateway>" }.first

      expect(declared.fetch(CONTRACT::NODE_ROLE_KEY)).to eq("action")
      expect(declared.fetch("kind")).to eq("external")
    end

    it "M-28 CONTROL — deriving kind from an action-ish category makes it FIRE" do
      mutated = deep_dup(graph)
      mutated.fetch("nodes").find { |n| symbol_of(id_map, n["id"]) == "<external:queue:OutOfTreeWorker>" }["kind"] = "db_op"

      # NOTE the discriminating half: the ENGINE VALIDATOR REJECTS NOTHING here.
      # `db_op` is a legal member of the closed kind enum, so the schema is
      # perfectly happy — which proves the SPEC, not the schema, is the guard.
      expect(CONTRACT::Validator.valid?(:graph, mutated)).to be(true)
      expect(kind_violations(mutated, id_map)).to include(/OutOfTreeWorker>: kind "db_op"/)
    end
  end

  # =====================================================================
  # THE MUTATIONS — a boundary rule's ROLE and a profile ROLE move NO score
  # =====================================================================
  describe "a declared boundary's role tag cannot move a score" do
    def findings_bytes(graph_doc)
      CONTRACT::Serializer.dump(findings_for(graph_doc))
    end

    it "NON-DEGENERACY: the fixture produces a POPULATED findings document" do
      findings = findings_for(graph)

      expect(findings["findings"]).not_to be_empty
      expect(findings.dig("scores", "egress", "score")).to be_a(Numeric)
    end

    it "rotating the DECLARED rule's role changes the graph but moves NO published number" do
      rotated_rule = DECLARED_CALL_RULE.merge("role" => "configuration")
      rotated = capture(boundary: { "paths" => [], "classes" => [], "calls" => [rotated_rule] })

      # The mutation can fire: the emitted bytes really did change.
      expect(CONTRACT::Serializer.dump(rotated.graph)).not_to eq(CONTRACT::Serializer.dump(graph))
      declared = nodes_with(rotated.graph, rotated.id_map).find { |_, s| s == "<external:http:Payments::Gateway>" }.first
      expect(declared.fetch(CONTRACT::NODE_ROLE_KEY)).to eq("configuration")

      # …and no number moved.
      expect(findings_bytes(rotated.graph)).to eq(findings_bytes(graph))
    end

    it "REMOVING the declared rule's role likewise moves nothing — presence is not a door either" do
      unroled = capture(
        boundary: { "paths" => [], "classes" => [], "calls" => [DECLARED_CALL_RULE.reject { |k, _| k == "role" }] }
      )
      declared = nodes_with(unroled.graph, unroled.id_map).find { |_, s| s == "<external:http:Payments::Gateway>" }.first

      expect(declared).not_to have_key(CONTRACT::NODE_ROLE_KEY) # ABSENT, not defaulted
      expect(findings_bytes(unroled.graph)).to eq(findings_bytes(graph))
    end

    it "rotating EVERY stamped role in the emitted graph moves nothing — including the crossing sinks" do
      enum    = %w[action configuration no_io]
      mutated = deep_dup(graph)
      mutated.fetch("nodes").each do |node|
        next unless node.key?(CONTRACT::NODE_ROLE_KEY)

        node[CONTRACT::NODE_ROLE_KEY] = enum[(enum.index(node[CONTRACT::NODE_ROLE_KEY]) + 1) % enum.size]
      end

      expect(CONTRACT::Serializer.dump(mutated)).not_to eq(CONTRACT::Serializer.dump(graph)) # it fired
      expect(findings_bytes(mutated)).to eq(findings_bytes(graph))
    end

    it "…while the CATEGORY is an HONEST scoring input, and moves one" do
      # The two-sided control that keeps the three invariances above from being
      # read as "nothing about a crossing matters". The role is inert; the
      # category is not, and never claimed to be.
      mutated = deep_dup(graph)
      mutated.fetch("nodes").find { |n| symbol_of(id_map, n["id"]) == "<external:gem:SomeGem>" }["terminal_kind"] = "http"

      expect(findings_bytes(mutated)).not_to eq(findings_bytes(graph))
    end
  end

  # --- the engine, driven for real ----------------------------------------

  # Run the SHIPPED analyze path over a graph document and return the findings.
  # No in-process shortcut: the claim is about published numbers, so the numbers
  # must come from the thing that publishes them.
  def findings_for(graph_doc)
    Tempfile.create(["graph", ".yml"]) do |graph_file|
      graph_file.write(CONTRACT::Serializer.dump(graph_doc))
      graph_file.flush
      out = Tempfile.new(["findings", ".yml"])
      out.close
      orig_out = $stdout
      orig_err = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      begin
        ArchitectureAuditor::CLI.call(arguments: ["analyze", graph_file.path, "--out", out.path])
      ensure
        $stdout = orig_out
        $stderr = orig_err
      end
      result = CONTRACT::Serializer.load(out.path)
      out.unlink
      return result
    end
  end

  def findings_bytes(graph_doc)
    CONTRACT::Serializer.dump(findings_for(graph_doc))
  end
end
