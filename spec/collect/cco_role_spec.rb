# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

# THE INERT ROLE TAG — STAMPING BEHAVIOUR (configurator W3 / C6, C7, C8).
#
# The engine's rev-1.1 reference profile declares a `role` per verb; this file
# owns what the CLIENT does with it. Three separable jobs, each with the
# fixture that a plausible-wrong implementation would still pass:
#
#   C6 db_op   — per-method, EXACT. Homogeneous by construction (the node
#                symbol embeds the verb), so the discriminating fixture is one
#                class whose db_ops DISAGREE: a single-verb fixture cannot tell
#                a correct per-verb lookup from a bug stamping one constant role
#                on every db_op.
#   C7 egress  — AGGREGATED over the call sites that merge into one sink.
#                The discriminating fixture is the DISAGREEING one: the
#                last-write-wins implementation passes every homogeneous case
#                and silently stamps "action" on a sink that is half reads.
#   C8 queue   — the DECLARED GAP. An in-tree enqueue becomes a real edge, so
#                there is no node for a role to ride; it is COUNTED, not hidden.
#
# ABSENCE IS ASSERTED WITH A GUARD, NEVER WITH `be_nil`. `node["cco_role"]` is
# nil both when the key is absent and when it was fabricated as an explicit
# null — and the graph schema REJECTS the second. `assert_absent!` below
# separates them and is itself pinned in both directions.
RSpec.describe "cco_role — the inert crossing-role tag (W3)" do
  R = Archbuddy::Collect::Adapters::Ruby
  ROLE_KEY = ArchitectureAuditor::Contract::NODE_ROLE_KEY

  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def in_repo(files)
    Dir.mktmpdir("archbuddy-cco-role") do |dir|
      files.each do |name, source|
        path = File.join(dir, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      yield dir
    end
  end

  def collect(dir)
    Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
  end

  def anonymize(dir)
    Archbuddy::Collect::Anonymizer.new(collect(dir), tool: "archbuddy test", adapter: "ruby").call
  end

  def role_of(result, symbol)
    result.nodes.find { |n| n.symbol == symbol }&.cco_role
  end

  # THE ABSENCE GUARD. Raises when +key+ is PRESENT under any value — including
  # the fabricated stand-ins for "nothing to say" (0, {}, [], "", explicit nil).
  # Returns true only on a genuine absence.
  def assert_absent!(hash, key)
    raise "FABRICATED ABSENCE: #{key.inspect} present as #{hash[key].inspect}" if hash.key?(key)

    true
  end

  # A model class plus a caller whose db_ops DISAGREE — a read, a write and a
  # non-crossing construction, all on the same receiver.
  def disagreeing_db_ops
    {
      "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
      "app/services/mixer.rb" => <<~RUBY
        class Mixer
          def run
            User.where(active: true)
            User.create!(name: "x")
            User.new
          end
        end
      RUBY
    }
  end

  # =====================================================================
  # THE ABSENCE GUARD ITSELF (nothing below is trusted until this passes)
  # =====================================================================
  describe "the absence guard is two-sided" do
    it "does NOT raise on a genuine absence" do
      expect(assert_absent!({ "kind" => "external" }, ROLE_KEY)).to be(true)
    end

    it "RAISES on every fabricated stand-in for absence" do
      [0, {}, [], "", nil, "unknown"].each do |fabrication|
        expect { assert_absent!({ ROLE_KEY => fabrication }, ROLE_KEY) }
          .to raise_error(/FABRICATED ABSENCE/),
              "a fabricated #{fabrication.inspect} slipped past the guard"
      end
    end
  end

  # =====================================================================
  # C6 — db_op, per-method and exact
  # =====================================================================
  describe "C6: db_op nodes carry the ORM verb's role" do
    it "DUAL, DISAGREEING: one class yields three db_ops with three DIFFERENT roles" do
      # `where` reads, `create!` writes, `new` does no I/O at all. A bug that
      # stamped a constant role (or the list's first role) on every db_op fails
      # on at least two of these three.
      in_repo(disagreeing_db_ops) do |dir|
        result = collect(dir)

        expect(role_of(result, "User.where")).to eq("configuration")
        expect(role_of(result, "User.create!")).to eq("action")
        expect(role_of(result, "User.new")).to eq("no_io")
      end
    end

    it "`no_io` is a STAMPED value, not an absence — the db_op that is not a crossing" do
      # This is the anchor that rules out mapping no_io onto "absent": a
      # non-crossing db_op must be visibly DECLARED as such, distinguishable
      # from a verb the profile never classified.
      in_repo(disagreeing_db_ops) do |dir|
        node = anonymize(dir).graph["nodes"].find { |n| n[ROLE_KEY] == "no_io" }

        expect(node).not_to be_nil
        expect(node["kind"]).to eq("db_op")
      end
    end

    it "the role rides EVERY db_op tier — implicit-self, const receiver and typed receiver" do
      files = {
        "app/models/user.rb" => <<~RUBY,
          class User < ApplicationRecord
            def self.recent
              where(active: true)
            end
          end
        RUBY
        "app/services/caller.rb" => <<~RUBY
          class Caller
            def go
              User.create!(name: "x")
            end

            def typed
              u = User.new
              u.touch
            end
          end
        RUBY
      }
      in_repo(files) do |dir|
        result = collect(dir)

        expect(role_of(result, "User.where")).to eq("configuration")  # R2 class context
        expect(role_of(result, "User.create!")).to eq("action")       # R4 const receiver
        expect(role_of(result, "User.touch")).to eq("action")         # R4.5 typed receiver
      end
    end

    it "the emitted graph key is the CONTRACT's property name, read from its producer" do
      in_repo(disagreeing_db_ops) do |dir|
        node = anonymize(dir).graph["nodes"].find { |n| n[ROLE_KEY] == "configuration" }

        expect(node).not_to be_nil
        expect(ROLE_KEY).to eq("cco_role") # the ONE place the string is written
      end
    end
  end

  # =====================================================================
  # C7 — egress, aggregated with ABSENT on disagreement
  # =====================================================================
  describe "C7: the egress sink's role is a UNANIMOUS aggregate" do
    def http_sink(result, target)
      result.graph["nodes"].find do |node|
        id = result.id_map["ids"].find { |_i, d| d["symbol"] == "<external:http:#{target}>" }&.first
        node["id"] == id
      end
    end

    it "DISAGREEING DIRECTION: get + post on one library ⇒ ONE sink, NO role, counted 1" do
      files = { "app.rb" => <<~RUBY }
        class Caller
          def go
            Faraday.get("/x")
            Faraday.post("/x")
          end
        end
      RUBY
      in_repo(files) do |dir|
        raw    = collect(dir)
        result = Archbuddy::Collect::Anonymizer.new(raw, tool: "t", adapter: "ruby").call

        sinks = raw.nodes.select { |n| n.symbol == "<external:http:Faraday>" }
        expect(sinks.size).to eq(1) # ONE sink — the tag never splits a node

        assert_absent!(http_sink(result, "Faraday"), ROLE_KEY)
        expect(raw.diagnostics[:cco_role_suppressed])
          .to eq({ Archbuddy::Collect::Adapters::Ruby::EgressRoleAggregate::HETEROGENEOUS => 1 })
      end
    end

    it "AGREEING DIRECTION: get alone ⇒ the role IS stamped, and NOTHING is suppressed" do
      # The two-sided control. Without it, a variant that always suppresses
      # would pass the disagreeing case above and look correct.
      files = { "app.rb" => <<~RUBY }
        class Caller
          def go
            Faraday.get("/x")
            Faraday.get("/y")
          end
        end
      RUBY
      in_repo(files) do |dir|
        raw    = collect(dir)
        result = Archbuddy::Collect::Anonymizer.new(raw, tool: "t", adapter: "ruby").call

        expect(http_sink(result, "Faraday")[ROLE_KEY]).to eq("configuration")
        expect(raw.diagnostics[:cco_role_suppressed]).to eq({})
      end
    end

    it "a DECLARED + UNDECLARED mix is a disagreement too — half-classified is not classified" do
      # `request` takes its verb as a runtime argument, so the profile leaves it
      # unroled. A sink that is `get` PLUS `request` cannot honestly be called a
      # read: nil is a distinct observed value, never a wildcard that agrees.
      files = { "app.rb" => <<~RUBY }
        class Caller
          def go
            Faraday.get("/x")
            Faraday.request(method: :get)
          end
        end
      RUBY
      in_repo(files) do |dir|
        raw    = collect(dir)
        result = Archbuddy::Collect::Anonymizer.new(raw, tool: "t", adapter: "ruby").call

        assert_absent!(http_sink(result, "Faraday"), ROLE_KEY)
        expect(raw.diagnostics[:cco_role_suppressed].values.sum).to eq(1)
      end
    end

    it "an ALL-UNDECLARED sink is absent WITHOUT being counted — the two zeros stay distinct" do
      files = { "app.rb" => <<~RUBY }
        class Caller
          def go
            Excon.request(method: :get)
          end
        end
      RUBY
      in_repo(files) do |dir|
        raw    = collect(dir)
        result = Archbuddy::Collect::Anonymizer.new(raw, tool: "t", adapter: "ruby").call

        assert_absent!(http_sink(result, "Excon"), ROLE_KEY)
        # "nothing was declared" is NOT "members disagreed".
        expect(raw.diagnostics[:cco_role_suppressed]).to eq({})
      end
    end

    it "the role table is scoped to :http — a gem call named `get` is NOT given HTTP semantics" do
      # `SomeGem` is not an egress root, so `SomeGem.get` classifies :gem. Its
      # verb happens to appear in the HTTP verb table; reading the role for it
      # would attribute one library's semantics to another.
      files = { "app.rb" => <<~RUBY }
        class Caller
          def go
            SomeGem.get(1)
          end
        end
      RUBY
      in_repo(files) do |dir|
        raw    = collect(dir)
        result = Archbuddy::Collect::Anonymizer.new(raw, tool: "t", adapter: "ruby").call
        id     = result.id_map["ids"].find { |_i, d| d["symbol"] == "<external:gem:SomeGem>" }&.first
        node   = result.graph["nodes"].find { |n| n["id"] == id }

        expect(node["terminal_kind"]).to eq("gem")
        assert_absent!(node, ROLE_KEY)
      end
    end

    it "the GENERIC <external> sink is never stamped — no library, no claim" do
      files = { "app.rb" => <<~RUBY }
        class Caller
          def go
            mystery.call_it
          end
        end
      RUBY
      in_repo(files) do |dir|
        generic = collect(dir).nodes.find { |n| n.symbol == "<external>" }

        expect(generic).not_to be_nil
        expect(generic.cco_role).to be_nil
      end
    end

    it "a QUEUE sink carries no role — this build declares none for enqueue verbs" do
      # RECORDED PLAN-vs-SOURCE DIVERGENCE (W3): §7's C8 note expects an
      # out-of-tree enqueue to take `action` "for free". It cannot: the enqueue
      # verbs live in `framework.jobs.dispatch_verbs`, which the SHIPPED profile
      # schema types as a plain name list with no role column. Fabricating
      # `action` here would invent a declaration the profile does not make.
      files = { "app.rb" => <<~RUBY }
        class Caller
          def go
            OutOfTreeWorker.perform_async(1)
          end
        end
      RUBY
      in_repo(files) do |dir|
        raw    = collect(dir)
        result = Archbuddy::Collect::Anonymizer.new(raw, tool: "t", adapter: "ruby").call
        id     = result.id_map["ids"].find { |_i, d| d["symbol"] == "<external:queue:OutOfTreeWorker>" }&.first
        node   = result.graph["nodes"].find { |n| n["id"] == id }

        expect(node["terminal_kind"]).to eq("queue")
        assert_absent!(node, ROLE_KEY)
      end
    end
  end

  # =====================================================================
  # C8 — the A10 queue fork: declared and counted
  # =====================================================================
  describe "C8: the in-tree enqueue is a DECLARED gap" do
    it "DISAGREEING PAIR: in-tree enqueue ⇒ counted, edge kept, NO queue sink" do
      files = {
        "app/jobs/mailer_worker.rb" => <<~RUBY,
          class MailerWorker
            include Sidekiq::Job

            def perform(id)
              id
            end
          end
        RUBY
        "app/services/enqueuer.rb" => <<~RUBY
          class Enqueuer
            def call
              MailerWorker.perform_async(1)
            end
          end
        RUBY
      }
      in_repo(files) do |dir|
        raw = collect(dir)

        expect(raw.diagnostics[:cco_role_unattachable]).to eq({ queue_dispatch_in_tree: 1 })
        # The recovered edge is UNCHANGED — the counter observes, never diverts.
        target = raw.nodes.find { |n| n.symbol == "MailerWorker#perform" }
        caller_node = raw.nodes.find { |n| n.symbol == "Enqueuer#call" }
        expect(raw.edges.map { |e| [e.from_key, e.to_key] })
          .to include([caller_node.real_key, target.real_key])
        expect(raw.nodes.map(&:symbol).grep(/external:queue/)).to eq([])
      end
    end

    it "OTHER ARM: an OUT-OF-TREE enqueue mints a sink and is NOT counted" do
      files = { "app.rb" => <<~RUBY }
        class Enqueuer
          def call
            OutOfTreeWorker.perform_async(1)
          end
        end
      RUBY
      in_repo(files) do |dir|
        raw = collect(dir)

        expect(raw.diagnostics[:cco_role_unattachable]).to eq({})
        expect(raw.nodes.map(&:symbol)).to include("<external:queue:OutOfTreeWorker>")
      end
    end
  end

  # =====================================================================
  # DEGENERATE INPUTS
  # =====================================================================
  describe "degenerate profiles" do
    def with_profile(document)
      allow(R::Profile).to receive(:for).and_return(R::Profile.new(document))
      yield
    end

    def shipped_document
      JSON.parse(JSON.generate(R::Profile::Profiles.load(R::Profile::DEFAULT_ID)))
    end

    def role_stripped(node)
      case node
      when Hash  then node.each_with_object({}) { |(k, v), h| h[k] = role_stripped(v) unless k == "role" }
      when Array then node.map { |v| role_stripped(v) }
      else node
      end
    end

    it "a rev-1.0 (role-free) profile stamps NOTHING and crashes nothing" do
      with_profile(role_stripped(shipped_document)) do
        in_repo(disagreeing_db_ops) do |dir|
          raw = collect(dir)

          expect(raw.nodes.map(&:cco_role).compact).to eq([])
          expect(raw.nodes.count { |n| n.kind == "db_op" }).to eq(3) # still three nodes
        end
      end
    end

    it "an EMPTY orm.methods list yields zero db_ops and zero roles, without raising" do
      document = shipped_document
      document["framework"]["orm"]["methods"] = []

      with_profile(document) do
        in_repo(disagreeing_db_ops) do |dir|
          raw = nil
          expect { raw = collect(dir) }.not_to raise_error
          expect(raw.nodes.count { |n| n.kind == "db_op" }).to eq(0)
          expect(raw.nodes.map(&:cco_role).compact).to eq([])
        end
      end
    end

    it "an EMPTY library.egress list leaves every sink unroled, without raising" do
      document = shipped_document
      document["library"]["egress"] = []

      with_profile(document) do
        files = { "app.rb" => "class C\n  def go\n    Faraday.get(\"/x\")\n  end\nend\n" }
        in_repo(files) do |dir|
          raw = nil
          expect { raw = collect(dir) }.not_to raise_error
          expect(raw.nodes.select { |n| n.kind == "external" }.map(&:cco_role).compact).to eq([])
          expect(raw.diagnostics[:cco_role_suppressed]).to eq({})
        end
      end
    end
  end

  # =====================================================================
  # THE AGGREGATE, UNIT-LEVEL
  # =====================================================================
  describe R::EgressRoleAggregate do
    def call_record(category, target, role)
      { from_fq: "C#go", to: { type: :external, category: category, target: target, cco_role: role } }
    end

    it "MUTATION SENTINEL: last-write-wins would stamp where unanimity abstains" do
      records = [call_record(:http, "F", "configuration"), call_record(:http, "F", "action")]
      aggregate = described_class.new(records)

      # The plausible-wrong implementation returns "action" here.
      expect(aggregate.role_for(:http, "F")).to be_nil
      expect(aggregate.suppressed).to eq({ described_class::HETEROGENEOUS => 1 })
    end

    it "aggregates each [category, target] pair INDEPENDENTLY" do
      records = [
        call_record(:http, "A", "configuration"), call_record(:http, "A", "configuration"),
        call_record(:http, "B", "configuration"), call_record(:http, "B", "action"),
        call_record(:gem,  "A", "action")
      ]
      aggregate = described_class.new(records)

      expect(aggregate.role_for(:http, "A")).to eq("configuration")
      expect(aggregate.role_for(:http, "B")).to be_nil
      expect(aggregate.role_for(:gem, "A")).to eq("action")
      expect(aggregate.suppressed).to eq({ described_class::HETEROGENEOUS => 1 })
    end

    it "ignores records that mint no per-target sink (no target, or not external)" do
      records = [
        { from_fq: "C#go", to: { type: :external, category: nil, target: nil, cco_role: nil } },
        { from_fq: "C#go", to: { type: :db_op, fq: "User.where" } },
        { from_fq: "C#go", to: { type: :method, fq: "X#y" } }
      ]
      aggregate = described_class.new(records)

      expect(aggregate.role_for(nil, nil)).to be_nil
      expect(aggregate.suppressed).to eq({})
    end

    it "an EMPTY call list gives an EMPTY tally — not a fabricated zero row" do
      aggregate = described_class.new([])

      expect(aggregate.suppressed).to eq({})
      expect(aggregate.suppressed).to be_empty
      assert_absent!(aggregate.suppressed, described_class::HETEROGENEOUS)
    end
  end
end
