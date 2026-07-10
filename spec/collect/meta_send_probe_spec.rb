# frozen_string_literal: true

require "tmpdir"

# END-TO-END literal meta-dispatch probe (v0.10 W1-D, L21). Feeds inline
# source through the REAL adapter + Anonymizer and asserts that a literal
# meta-dispatch (`recv.send(:m)` / `public_send` / `__send__` / `try` /
# `try!`) resolves to a single `caller -> Target#m` edge IFF the rewritten
# target is a known method node — and DECLINES to the shared `<external>`
# sink when the target is absent / the receiver is unprovable. Dynamic-arg
# send stays a FLAGGED metaprogramming blind spot (R1, narrowed); dynamic-arg
# try falls to `<external>` unflagged (pre-v0.10 parity). Provenance rides
# diagnostics[:probe_edges][:meta_send] only, never the serialized graph.
RSpec.describe "MetaSend probe (W1-D e2e)" do
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

  def anonymize(dir)
    Archbuddy::Collect::Anonymizer.new(
      collect(dir), tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  def id_for(result, sym)
    result.id_map["ids"].find { |_i, d| d["symbol"] == sym }&.first
  end

  def edge_exists?(result, from_sym, to_sym)
    from_id = id_for(result, from_sym)
    to_id   = id_for(result, to_sym)
    return false if from_id.nil? || to_id.nil?

    result.graph["edges"].any? { |e| e["from"] == from_id && e["to"] == to_id }
  end

  # A target class with instance + singleton methods, plus a caller slot.
  def target_and_caller(call_expr, setup: nil)
    <<~RUBY
      class Target
        def ping
          1
        end

        def self.status
          :ok
        end
      end

      class Caller
        def go
          #{setup}
          #{call_expr}
        end
      end
    RUBY
  end

  it "registers :meta_send in the probe registry (after :sidekiq_dispatch)" do
    # Relative order only — the exact-list pin lives in probe_seam_spec (and
    # is re-baselined per wave as probes register; EgressProbe joins LAST in W2-C).
    names = Archbuddy::Collect::Adapters::Ruby::ProbeRegistry.for(config).map(&:name)
    expect(names).to include(:meta_send)
    expect(names.index(:sidekiq_dispatch)).to be < names.index(:meta_send)
  end

  %w[send public_send __send__].each do |verb|
    it "resolves Const.#{verb}(:status) to a Caller#go -> Target.status edge" do
      in_repo(target_and_caller("Target.#{verb}(:status)")) do |dir|
        result = anonymize(dir)
        expect(edge_exists?(result, "Caller#go", "Target.status")).to be(true)

        # REPLACE-not-stack (P6): the resolved site is NOT also an <external> edge.
        go_id  = id_for(result, "Caller#go")
        ext_id = id_for(result, "<external>")
        ext_edge = result.graph["edges"].find { |e| e["from"] == go_id && e["to"] == ext_id }
        expect(ext_edge).to be_nil
      end
    end
  end

  it "resolves a TYPED receiver send to the instance method (x = Target.new; x.send(:ping))" do
    in_repo(target_and_caller("t.send(:ping)", setup: "t = Target.new")) do |dir|
      result = anonymize(dir)
      expect(edge_exists?(result, "Caller#go", "Target#ping")).to be(true)
    end
  end

  it "resolves a literal STRING dispatch name (t.send(\"ping\"))" do
    in_repo(target_and_caller(%(t.send("ping")), setup: "t = Target.new")) do |dir|
      result = anonymize(dir)
      expect(edge_exists?(result, "Caller#go", "Target#ping")).to be(true)
    end
  end

  %w[try try!].each do |verb|
    it "resolves t.#{verb}(:ping) on a typed receiver to Target#ping" do
      in_repo(target_and_caller("t.#{verb}(:ping)", setup: "t = Target.new")) do |dir|
        result = anonymize(dir)
        expect(edge_exists?(result, "Caller#go", "Target#ping")).to be(true)
      end
    end
  end

  it "resolves an implicit-self literal send inside the enclosing class" do
    source = <<~RUBY
      class Dispatcher
        def run
          send(:work)
        end

        def work
          1
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = anonymize(dir)
      expect(edge_exists?(result, "Dispatcher#run", "Dispatcher#work")).to be(true)
      expect(collect(dir).diagnostics[:meta_sites_skipped]).to eq(0)
    end
  end

  it "declines (-> <external>) when the literal target is NOT in the table" do
    in_repo(target_and_caller("Target.send(:absent_method)")) do |dir|
      result = anonymize(dir)
      # No fabricated node (I1 never-fabricate).
      expect(id_for(result, "Target#absent_method")).to be_nil
      expect(id_for(result, "Target.absent_method")).to be_nil
      go_id  = id_for(result, "Caller#go")
      ext_id = id_for(result, "<external>")
      expect(ext_id).not_to be_nil
      ext_edge = result.graph["edges"].find { |e| e["from"] == go_id && e["to"] == ext_id }
      expect(ext_edge).not_to be_nil
      # And it is NOT flagged as a metaprogramming blind spot (literal arg).
      expect(collect(dir).diagnostics[:meta_sites_skipped]).to eq(0)
    end
  end

  it "declines for an unprovable receiver (helper().send(:ping))" do
    in_repo(target_and_caller("helper().send(:ping)")) do |dir|
      result = anonymize(dir)
      expect(edge_exists?(result, "Caller#go", "Target#ping")).to be(false)
    end
  end

  it "leaves a DYNAMIC send flagged (R1) with no edge" do
    in_repo(target_and_caller("t.send(name)", setup: "t = Target.new; name = compute")) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:meta_sites_skipped]).to eq(1)
      expect(result.diagnostics[:probe_edges].fetch(:meta_send, 0)).to eq(0)
    end
  end

  it "leaves a DYNAMIC try unflagged and routed to <external> (pre-v0.10 parity)" do
    in_repo(target_and_caller("t.try(name)", setup: "t = Target.new; name = compute")) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:meta_sites_skipped]).to eq(0)
      expect(result.diagnostics[:probe_edges].fetch(:meta_send, 0)).to eq(0)
      anon = anonymize(dir)
      expect(id_for(anon, "<external>")).not_to be_nil
    end
  end

  it "tallies resolved meta-dispatch edges in diagnostics[:probe_edges][:meta_send]" do
    source = <<~RUBY
      class Target
        def ping
          1
        end
      end

      class Caller
        def go
          t = Target.new
          t.send(:ping)
          t.try(:ping)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:probe_edges][:meta_send]).to eq(2)
      expect(result.diagnostics[:meta_resolved]).to eq(2)
    end
  end

  it "keeps the meta_send tally OUT of the serialized graph" do
    in_repo(target_and_caller("Target.send(:status)")) do |dir|
      anon = anonymize(dir)
      serialized = ArchitectureAuditor::Contract::Serializer.dump(anon.graph)
      expect(serialized).not_to include("meta_send")
      expect(serialized).not_to include("meta_resolved")
      expect(serialized).not_to include("total_call_sites")
      expect(serialized).not_to include("provenance")
      expect(anon.graph).not_to have_key("diagnostics")
    end
  end

  it "produces a graph that validates against the engine's graph schema" do
    in_repo(target_and_caller("Target.send(:status)")) do |dir|
      graph = anonymize(dir).graph
      expect {
        ArchitectureAuditor::Contract::Validator.validate!(:graph, graph)
      }.not_to raise_error
    end
  end
end
