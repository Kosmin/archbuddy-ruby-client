# frozen_string_literal: true

require "tmpdir"

# END-TO-END egress classification probe (v0.10 W2-C, L16/L18). Feeds inline
# source through the REAL adapter and asserts the EgressProbe's category
# decisions on PROVABLE literal-constant receivers:
#   :http  — known HTTP-client constant root + HTTP verb (Faraday.get)
#   :gem   — literal constant absent from the SymbolTable (out-of-tree gem)
#   :queue — the DispatchProbe-declined enqueue shape (perform_* on a const
#            whose #perform is NOT in-tree)
#   DECLINE — variable/computed receiver, or an in-tree constant → the call
#            stays the generic <external> bucket (:generic tally, CR-3).
# NEVER-FABRICATE (I1): the probe never mints an in-tree edge — it only
# enriches the existing external action with a category.
RSpec.describe "Egress probe (W2-C e2e)" do
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

  def caller_with(call_expr, setup: nil)
    <<~RUBY
      class Caller
        def go
          #{setup}
          #{call_expr}
        end
      end
    RUBY
  end

  def egress_counts_for(call_expr, setup: nil)
    in_repo(caller_with(call_expr, setup: setup)) do |dir|
      return collect(dir).diagnostics[:egress_counts]
    end
  end

  it "registers :egress LAST in the probe registry" do
    names = Archbuddy::Collect::Adapters::Ruby::ProbeRegistry.for(config).map(&:name)
    expect(names.last).to eq(:egress)
  end

  # --- :http — known HTTP constant root + verb -------------------------------

  %w[Faraday.get("/x") Net::HTTP.start("h") HTTParty.post("/x") RestClient.delete("/x")
     Typhoeus.head("/x") Excon.put("/x")].each do |expr|
    it "classifies #{expr} as :http" do
      expect(egress_counts_for(expr)).to eq({ http: 1 })
    end
  end

  it "classifies an Aws:: prefixed constant with an HTTP-ish verb as :http (Aws::S3::Client.new)" do
    # `new`/`open` are in the W2-C verb set — a client construction on a known
    # egress root is egress evidence (pinned per the wave spec, superseding
    # the deliverable plan's shorter verb list).
    expect(egress_counts_for("Aws::S3::Client.new")).to eq({ http: 1 })
  end

  # --- verb gate (the `HTTP` local-const collision, C-6) ----------------------

  it "does NOT classify HTTP.something_nonverb as :http (falls to :gem when out-of-tree)" do
    expect(egress_counts_for("HTTP.something_nonverb")).to eq({ gem: 1 })
  end

  it "declines entirely for an IN-TREE constant named HTTP (base tiers own it)" do
    source = <<~RUBY
      class HTTP
        def self.helper
          1
        end
      end

      class Caller
        def go
          HTTP.get_config
        end
      end
    RUBY
    in_repo(source) do |dir|
      # In-tree const + unknown method → probe declines → generic bucket.
      expect(collect(dir).diagnostics[:egress_counts]).to eq({ generic: 1 })
    end
  end

  # --- :gem — literal out-of-tree constant -----------------------------------

  it "classifies an out-of-tree literal constant call as :gem (SomeGem::Client.foo)" do
    expect(egress_counts_for("SomeGem::Client.foo")).to eq({ gem: 1 })
  end

  # --- :queue — the DispatchProbe-declined enqueue shape ----------------------

  it "classifies OutOfTreeWorker.perform_async (no in-tree #perform) as :queue" do
    expect(egress_counts_for("OutOfTreeWorker.perform_async(1)")).to eq({ queue: 1 })
  end

  it "never sees an IN-TREE enqueue (DispatchProbe resolves it to an edge first)" do
    source = <<~RUBY
      class InTreeWorker
        def perform(x)
          x
        end
      end

      class Caller
        def go
          InTreeWorker.perform_async(1)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:probe_edges]).to eq({ sidekiq_dispatch: 1 })
      expect(result.diagnostics[:egress_counts]).to eq({})
    end
  end

  # --- DECLINE — unprovable receivers stay generic (I1) ----------------------

  it "declines a variable receiver (client.get) -> :generic bucket" do
    expect(egress_counts_for("client.get(\"/x\")", setup: "client = build_client"))
      .to eq({ generic: 2 }) # build_client + client.get both unresolved-generic
  end

  it "declines a computed chain (Faraday.new.get) for classification of the chained call" do
    # The INNER `Faraday.new` is a literal-constant :http call; the OUTER
    # `.get` has a CallNode receiver — unprovable → :generic (typed-var HTTP
    # egress is deferred, Open Question 3).
    expect(egress_counts_for("Faraday.new.get(\"/x\")")).to eq({ http: 1, generic: 1 })
  end

  it "never fabricates a node for the classified constant (I1)" do
    in_repo(caller_with("Faraday.get(\"/x\")")) do |dir|
      result = collect(dir)
      # No RawNode carries the real out-of-tree symbol — only the fixed-vocab
      # category sink exists (SECRET-safe, I8).
      expect(result.nodes.map(&:symbol)).not_to include("Faraday")
      expect(result.nodes.map(&:symbol)).not_to include("Faraday.get")
      expect(result.nodes.map(&:symbol)).to include("<external:http>")
    end
  end

  it "tallies mixed categories per call site" do
    source = <<~RUBY
      class Caller
        def go
          Faraday.get("/x")
          SomeGem::Client.foo
          OutOfTreeWorker.perform_async(1)
          mystery.call_it
        end
      end
    RUBY
    in_repo(source) do |dir|
      counts = collect(dir).diagnostics[:egress_counts]
      # `mystery` (bare accessor, untyped) + `mystery.call_it` are generic.
      expect(counts[:http]).to eq(1)
      expect(counts[:gem]).to eq(1)
      expect(counts[:queue]).to eq(1)
      expect(counts[:generic]).to be >= 1
      expect(counts.keys.sort).to eq(%i[gem generic http queue])
    end
  end
end
