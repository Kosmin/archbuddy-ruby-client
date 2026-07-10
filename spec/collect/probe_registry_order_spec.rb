# frozen_string_literal: true

require "tmpdir"

# Probe registry ORDER (v0.10 W2-C). The final order is
# [GrapeProbe, DispatchProbe, MetaSendProbe, EgressProbe] — EgressProbe LAST,
# so edge-recovering probes always win before egress classification. This
# spec pins the cross-probe claim boundaries the order protects:
#   - `Faraday.get` (an HTTP egress shape) is NOT eaten by MetaSendProbe
#     (`get` is not a meta-dispatch verb) — EgressProbe claims it.
#   - `x.send(:foo)` (a meta-dispatch shape) is NOT eaten by EgressProbe —
#     a resolvable literal send becomes a MetaSendProbe EDGE (never egress);
#     an unresolvable one falls to the GENERIC bucket (EgressProbe declines
#     non-constant receivers).
RSpec.describe "Probe registry order (W2-C)" do
  RB = Archbuddy::Collect::Adapters::Ruby unless defined?(RB)

  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def in_repo(source, filename: "app.rb")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, filename), source)
      yield dir
    end
  end

  def collect(dir)
    Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
  end

  it "pins the FINAL probe order: grape, sidekiq_dispatch, meta_send, egress (egress LAST)" do
    expect(RB::ProbeRegistry::PROBES).to eq(
      [RB::Probes::GrapeProbe, RB::Probes::DispatchProbe,
       RB::Probes::MetaSendProbe, RB::Probes::EgressProbe]
    )
    expect(RB::ProbeRegistry.for(config).map(&:name))
      .to eq(%i[grape sidekiq_dispatch meta_send egress])
  end

  it "Faraday.get is claimed by EgressProbe (:http), never by MetaSendProbe" do
    source = <<~RUBY
      class Caller
        def go
          Faraday.get("/x")
        end
      end
    RUBY
    in_repo(source) do |dir|
      diagnostics = collect(dir).diagnostics
      expect(diagnostics[:probe_edges]).to eq({ egress: 1 })
      expect(diagnostics[:probe_edges]).not_to have_key(:meta_send)
      expect(diagnostics[:egress_counts]).to eq({ http: 1 })
      expect(diagnostics[:meta_resolved]).to eq(0)
    end
  end

  it "a resolvable x.send(:foo) is claimed by MetaSendProbe (edge), never by EgressProbe" do
    source = <<~RUBY
      class Target
        def foo
          1
        end
      end

      class Caller
        def go
          x = Target.new
          x.send(:foo)
        end
      end
    RUBY
    in_repo(source) do |dir|
      diagnostics = collect(dir).diagnostics
      expect(diagnostics[:probe_edges][:meta_send]).to eq(1)
      expect(diagnostics[:meta_resolved]).to eq(1)
      # The resolved send is an EDGE, not an egress-categorized external:
      # no egress tally for it (Target.new is in-tree-const-declined generic).
      expect(diagnostics[:egress_counts]).not_to have_key(:http)
      expect(diagnostics[:egress_counts]).not_to have_key(:gem)
      expect(diagnostics[:egress_counts]).not_to have_key(:queue)
    end
  end

  it "an unresolvable variable send falls to the GENERIC bucket (EgressProbe declines)" do
    source = <<~RUBY
      class Caller
        def go
          x = helper
          x.send(:foo)
        end
      end
    RUBY
    in_repo(source) do |dir|
      diagnostics = collect(dir).diagnostics
      # helper + x.send(:foo) both unresolved → generic; NEVER :gem/:queue
      # (variable receiver is not provable egress evidence, I1).
      expect(diagnostics[:egress_counts]).to eq({ generic: 2 })
      expect(diagnostics[:probe_edges]).to eq({})
    end
  end
end
