# frozen_string_literal: true

require "prism"

# Focused unit coverage for the pluggable probe SEAM (W1 / P1): drives
# RubyResolver / ProbeRegistry / Probe / ResolutionPass directly with a
# test-only FAKE probe. Ships ZERO concrete probes — proves the infrastructure
# (R5-after-R4 ordering, decline -> R9 fallthrough, REPLACE-not-stack,
# provenance stamp, first-non-nil-wins, the diagnostics tally, backward-compat).
RSpec.describe "Probe seam (W1 / P1)" do
  M = Archbuddy::Collect::Adapters::Ruby

  # A fake edge probe: claims ONLY a specific call name, returning a method edge
  # to a fixed target. Mirrors the L2 contract (a real probe would gate on
  # ctx.table.method?) but is deterministic for the seam test.
  fake_edge_probe = Class.new(M::Probe) do
    def self.probe_name = :fake

    def initialize(target_fq, claim_name: "fan_out")
      @target_fq  = target_fq
      @claim_name = claim_name
    end

    def name = :fake

    def resolve(ctx)
      return nil unless ctx.name.to_s == @claim_name

      M::RubyResolver::Resolution.new(
        tier: :probe_fake, action: :edge, target_fq: @target_fq, kind: nil
      )
    end
  end

  # A fake probe that always declines.
  fake_decline_probe = Class.new(M::Probe) do
    def self.probe_name = :decliner
    def name = :decliner
    def resolve(_ctx) = nil
  end

  # A fake probe that claims but leaves provenance nil (so the R5 loop must
  # stamp it from #name).
  fake_unstamped_probe = Class.new(M::Probe) do
    def self.probe_name = :stamper
    def name = :stamper

    def resolve(ctx)
      return nil unless ctx.name.to_s == "needs_stamp"

      M::RubyResolver::Resolution.new(
        tier: :probe_stamper, action: :edge, target_fq: "Anything#go", kind: nil
      )
    end
  end

  # A symbol table double exposing only what the resolver consults.
  let(:empty_table) do
    Class.new do
      def method?(_fq) = false
      def active_record_class?(_fq) = false
    end.new
  end

  # A table that knows a single Const method (for the R4-resolves test).
  let(:const_table) do
    Class.new do
      def method?(fq) = fq == "Helper.do_it"
      def active_record_class?(_fq) = false
    end.new
  end

  def ctx_for(name, receiver: nil, table:)
    M::RubyResolver::CallContext.new(
      name: name, receiver: receiver, enclosing_class: nil, table: table, node: nil
    )
  end

  def const_receiver(const_name)
    Prism.parse("#{const_name}.do_it").value.statements.body.first.receiver
  end

  # --- backward-compat ---------------------------------------------------------

  it "constructs RubyResolver with the 1-arg ctor (no probes:)" do
    expect { M::RubyResolver.new(empty_table) }.not_to raise_error
  end

  it "constructs ResolutionPass with the 2-arg ctor (no probes:)" do
    acc = M::Accumulator.new
    expect { M::ResolutionPass.new(empty_table, acc) }.not_to raise_error
  end

  # --- Probe abstract contract -------------------------------------------------

  it "raises NotImplementedError for the abstract Probe#name" do
    expect { M::Probe.new.name }.to raise_error(NotImplementedError, /name/)
  end

  it "raises NotImplementedError for the abstract Probe#resolve" do
    expect { M::Probe.new.resolve(nil) }.to raise_error(NotImplementedError, /resolve/)
  end

  # --- tier ordering: probe runs AFTER R4 --------------------------------------

  it "never consults a probe for a call R4 already resolves (probe runs after R4)" do
    resolver = M::RubyResolver.new(const_table, probes: [fake_edge_probe.new("X#y", claim_name: "do_it")])
    ctx = ctx_for(:do_it, receiver: const_receiver("Helper"), table: const_table)

    res = resolver.resolve(ctx)
    expect(res.tier).to eq(:const_singleton)   # R4 fired, NOT :probe_fake
    expect(res.target_fq).to eq("Helper.do_it")
    expect(res.provenance).to be_nil
  end

  # --- decline -> R9 fallthrough -----------------------------------------------

  it "falls through to R9 <external> when the only probe declines" do
    resolver = M::RubyResolver.new(empty_table, probes: [fake_decline_probe.new])
    res = resolver.resolve(ctx_for(:whatever, table: empty_table))

    expect(res.tier).to eq(:external)
    expect(res.action).to eq(:external)
    expect(res.provenance).to be_nil
  end

  it "is byte-identical to today with empty probes (every unresolved call -> R9)" do
    resolver = M::RubyResolver.new(empty_table, probes: [])
    res = resolver.resolve(ctx_for(:anything, table: empty_table))

    expect(res.tier).to eq(:external)
    expect(res.action).to eq(:external)
  end

  # --- claim REPLACES external (P6, single Resolution) -------------------------

  it "returns the probe's single Resolution (REPLACE, never stacks a 2nd external)" do
    resolver = M::RubyResolver.new(empty_table, probes: [fake_edge_probe.new("Worker#perform")])
    res = resolver.resolve(ctx_for(:fan_out, table: empty_table))

    expect(res).to be_a(M::RubyResolver::Resolution)
    expect(res.action).to eq(:edge)
    expect(res.target_fq).to eq("Worker#perform")
    expect(res.tier).to eq(:probe_fake)
    # A single Resolution is returned; the call never ALSO yields :external.
    expect(res.action).not_to eq(:external)
  end

  # --- provenance stamp --------------------------------------------------------

  it "stamps provenance from #name when the probe leaves it nil" do
    resolver = M::RubyResolver.new(empty_table, probes: [fake_unstamped_probe.new])
    res = resolver.resolve(ctx_for(:needs_stamp, table: empty_table))

    expect(res.provenance).to eq(:stamper)
  end

  it "preserves provenance the probe sets itself" do
    self_stamping = Class.new(M::Probe) do
      def name = :outer
      def resolve(ctx)
        return nil unless ctx.name.to_s == "go"

        M::RubyResolver::Resolution.new(
          tier: :probe_outer, action: :edge, target_fq: "A#b", kind: nil, provenance: :inner
        )
      end
    end
    resolver = M::RubyResolver.new(empty_table, probes: [self_stamping.new])
    res = resolver.resolve(ctx_for(:go, table: empty_table))

    expect(res.provenance).to eq(:inner) # not overwritten by ||=
  end

  # --- first non-nil wins ------------------------------------------------------

  it "returns the first non-nil probe result (decliner skipped, order preserved)" do
    resolver = M::RubyResolver.new(
      empty_table, probes: [fake_decline_probe.new, fake_edge_probe.new("Late#hit")]
    )
    res = resolver.resolve(ctx_for(:fan_out, table: empty_table))

    expect(res.target_fq).to eq("Late#hit")
    expect(res.provenance).to eq(:fake)
  end

  # --- ResolutionPass tally ----------------------------------------------------

  it "tallies probe-resolved call sites on the Accumulator by probe name" do
    src = <<~RUBY
      class Dispatcher
        def run
          fan_out
          fan_out
        end
      end
    RUBY
    table = empty_table
    acc   = M::Accumulator.new
    pass  = M::ResolutionPass.new(table, acc, probes: [fake_edge_probe.new("Worker#perform")])
    Prism.parse(src).value.accept(pass)

    expect(acc.probe_edges).to eq({ fake: 2 })
  end

  it "leaves probe_edges empty ({}) when no probe resolves a call" do
    src = <<~RUBY
      class Plain
        def run
          something
        end
      end
    RUBY
    acc  = M::Accumulator.new
    pass = M::ResolutionPass.new(empty_table, acc, probes: [fake_decline_probe.new])
    Prism.parse(src).value.accept(pass)

    expect(acc.probe_edges).to eq({})
  end

  # --- ProbeRegistry selection -------------------------------------------------

  it "ships a frozen PROBES list holding the W3 concrete probes" do
    expect(M::ProbeRegistry::PROBES).to eq([M::Probes::GrapeProbe, M::Probes::DispatchProbe])
    expect(M::ProbeRegistry::PROBES).to be_frozen
  end

  it "selects from the real PROBES map by config (W3 registry populated)" do
    # :all selects every registered probe in order.
    expect(M::ProbeRegistry.for(Archbuddy::Collect::Config.new).map(&:name))
      .to eq(%i[grape sidekiq_dispatch])
    # an unknown name selects nothing (F2 — lenient, no raise).
    expect(M::ProbeRegistry.for(Archbuddy::Collect::Config.new(probes: %i[fake]))).to eq([])
    # :none selects nothing.
    expect(M::ProbeRegistry.for(Archbuddy::Collect::Config.new(probes: :none))).to eq([])
    # a named subset selects only that probe.
    expect(M::ProbeRegistry.for(Archbuddy::Collect::Config.new(probes: %i[grape])).map(&:name))
      .to eq([:grape])
  end

  it "selects and instantiates only the named probes (proven via a stubbed PROBES)" do
    # Registry probes are stateless with a no-arg ctor (the real-probe contract).
    fake_a = Class.new(M::Probe) do
      def self.probe_name = :fake_a
      def name = :fake_a
      def resolve(_ctx) = nil
    end
    fake_b = Class.new(M::Probe) do
      def self.probe_name = :fake_b
      def name = :fake_b
      def resolve(_ctx) = nil
    end
    stub_const("#{M::ProbeRegistry}::PROBES", [fake_a, fake_b])

    all = M::ProbeRegistry.for(Archbuddy::Collect::Config.new(probes: :all))
    expect(all.map(&:class)).to eq([fake_a, fake_b])

    one = M::ProbeRegistry.for(Archbuddy::Collect::Config.new(probes: %i[fake_a]))
    expect(one.map(&:name)).to eq([:fake_a])

    none = M::ProbeRegistry.for(Archbuddy::Collect::Config.new(probes: :none))
    expect(none).to eq([])
  end

  # --- Config probe normalization (F2 — lenient, never raises) -----------------

  it "normalizes probe selection leniently and never raises on unknown names" do
    expect(Archbuddy::Collect::Config.new.probes).to eq(:all)
    expect(Archbuddy::Collect::Config.new(probes: :none).probes).to eq([])
    expect(Archbuddy::Collect::Config.new(probes: nil).probes).to eq([])
    expect(Archbuddy::Collect::Config.new(probes: %w[grape]).probes).to eq([:grape])
    expect(Archbuddy::Collect::Config.new(probes: "grape, sidekiq_dispatch").probes)
      .to eq(%i[grape sidekiq_dispatch])
    expect { Archbuddy::Collect::Config.new(probes: %i[totally_unknown]) }.not_to raise_error
  end
end
