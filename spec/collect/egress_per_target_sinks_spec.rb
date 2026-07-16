# frozen_string_literal: true

require "tmpdir"
require "yaml"

# Per-target egress sub-sinks (v0.11 E1, L13): one sink per DISTINCT provable
# [category, target] pair — symbol `<external:{category}:{const_fq}>`,
# terminal_kind = the CATEGORY word — plus the always-minted generic
# `<external>` for target-less records. This battery owns the E1 contract:
#   a. mint determinism (sorted [category.to_s, target] order — a pure
#      function of the pair set, never discovery order)
#   b. distinct-target counting + same-caller calls-collapse (the I8 trace)
#   c. normalization fold (cbase `::Foo` ≡ `Foo`; C5 whitespace collapse)
#   d. the L13 SECRET assertion (targets live in the id-map descriptor ONLY,
#      never the serialized graph; node key set unchanged — multiplicity-only)
#   e. generic fallback (variable receivers / computed chains never mint)
#   f. live engine graph-1.3 validation with many per-target sinks
RSpec.describe "Egress per-target sub-sinks (E1)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def in_repo(files)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
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

  def external_symbols(raw)
    raw.nodes.select { |n| n.kind == "external" }.map(&:symbol)
  end

  # --- a. mint determinism ----------------------------------------------------

  it "emits byte-identical serialized graphs across two independent runs" do
    files = {
      "app.rb" => <<~RUBY
        class Caller
          def go
            Faraday.get("/x")
            ZGem.z
            AGem.a
            OutOfTreeWorker.perform_async(1)
          end
        end
      RUBY
    }
    dumps = Array.new(2) do
      in_repo(files) { |dir| YAML.dump(anonymize(dir).graph) }
    end
    expect(dumps[0]).to eq(dumps[1])
  end

  it "orders sinks by sorted [category, target], not discovery order (shuffled files)" do
    # Repo A discovers ZzzGem (file a.rb) before AaaGem (file b.rb); repo B
    # reverses the file arrangement. The external-sink sequence must be the
    # SAME sorted order in both — a pure function of the pair set.
    repo_a = {
      "a.rb" => "class CallerOne\n  def go\n    ZzzGem.z\n  end\nend\n",
      "b.rb" => "class CallerTwo\n  def go\n    AaaGem.a\n  end\nend\n"
    }
    repo_b = {
      "a.rb" => "class CallerTwo\n  def go\n    AaaGem.a\n  end\nend\n",
      "b.rb" => "class CallerOne\n  def go\n    ZzzGem.z\n  end\nend\n"
    }
    order_a = in_repo(repo_a) { |dir| external_symbols(collect(dir)) }
    order_b = in_repo(repo_b) { |dir| external_symbols(collect(dir)) }
    expect(order_a).to eq(order_b)
    expect(order_a).to eq(["<external>", "<external:gem:AaaGem>", "<external:gem:ZzzGem>"])
  end

  # --- b. distinct-target counting + calls-collapse (I8 trace) -----------------

  it "mints one sink per distinct [category, target]; same-caller repeats collapse to calls: 2" do
    files = {
      "app.rb" => <<~RUBY
        class CallerOne
          def go
            Faraday.get("/x")
            Aws::S3::Client.new
            GemA.call_one
            GemA.call_one
            GemB.other
          end
        end

        class CallerTwo
          def go
            GemA.call_one
          end
        end
      RUBY
    }
    in_repo(files) do |dir|
      result = anonymize(dir)
      raw_symbols = result.id_map["ids"].map { |_i, d| d["symbol"] }
      expect(raw_symbols).to include(
        "<external>",
        "<external:http:Aws::S3::Client>", "<external:http:Faraday>",
        "<external:gem:GemA>", "<external:gem:GemB>"
      )
      # Exactly 2 http + 2 gem pair sinks + the generic — never one-per-call-site.
      expect(raw_symbols.grep(/\A<external/).length).to eq(5)

      gem_a = id_for(result, "<external:gem:GemA>")
      one   = id_for(result, "CallerOne#go")
      two   = id_for(result, "CallerTwo#go")

      # Same caller hitting the same target twice = ONE edge, calls: 2.
      edge_one = result.graph["edges"].find { |e| e["from"] == one && e["to"] == gem_a }
      expect(edge_one["calls"]).to eq(2)
      # Distinct callers to the same target keep DISTINCT edges.
      edge_two = result.graph["edges"].find { |e| e["from"] == two && e["to"] == gem_a }
      expect(edge_two["calls"]).to eq(1)
    end
  end

  # --- c. normalization fold (cbase + C5 whitespace) ---------------------------

  it "folds ::SomeGem and SomeGem into ONE sink, edges from both callers landing on it" do
    files = {
      "a.rb" => "class CallerOne\n  def go\n    ::SomeGem.foo\n  end\nend\n",
      "b.rb" => "class CallerTwo\n  def go\n    SomeGem.foo\n  end\nend\n"
    }
    in_repo(files) do |dir|
      result = anonymize(dir)
      sink = id_for(result, "<external:gem:SomeGem>")
      expect(sink).not_to be_nil
      pair_sinks = result.id_map["ids"].select { |_i, d| d["symbol"].to_s.include?("SomeGem") }
      expect(pair_sinks.length).to eq(1)
      %w[CallerOne#go CallerTwo#go].each do |caller_sym|
        from = id_for(result, caller_sym)
        edge = result.graph["edges"].find { |e| e["from"] == from && e["to"] == sink }
        expect(edge).not_to be_nil, "expected #{caller_sym} -> <external:gem:SomeGem>"
      end
    end
  end

  it "folds a multi-line constant path into the whitespace-free sink (C5)" do
    files = {
      "a.rb" => "class CallerOne\n  def go\n    SomeGem::\n      Client.foo\n  end\nend\n",
      "b.rb" => "class CallerTwo\n  def go\n    SomeGem::Client.foo\n  end\nend\n"
    }
    in_repo(files) do |dir|
      raw = collect(dir)
      expect(external_symbols(raw)).to contain_exactly("<external>", "<external:gem:SomeGem::Client>")
    end
  end

  # --- d. the L13 SECRET assertion ---------------------------------------------

  it "keeps the target constant in the id-map descriptor and OUT of the serialized graph" do
    files = {
      "app.rb" => "class Caller\n  def go\n    PaymentsGem::Client.charge\n  end\nend\n"
    }
    in_repo(files) do |dir|
      result  = anonymize(dir)
      sink_id = id_for(result, "<external:gem:PaymentsGem::Client>")
      expect(sink_id).to start_with("ext_")

      # (1) The id-map descriptor carries the real-space symbol + category.
      descriptor = result.id_map["ids"].fetch(sink_id)
      expect(descriptor["symbol"]).to eq("<external:gem:PaymentsGem::Client>")
      expect(descriptor["terminal_kind"]).to eq("gem")
      expect(descriptor["file"]).to be_nil

      # (2) The serialized shareable graph NEVER contains the constant.
      expect(YAML.dump(result.graph)).not_to include("PaymentsGem")

      # (3) Node-hash key set unchanged (L7 multiplicity-only): the pair sink
      # carries exactly the pre-E1 category-sink keys; no new graph keys.
      node = result.graph["nodes"].find { |n| n["id"] == sink_id }
      expected = %w[id kind class_id loc self_time_ms total_time_ms count branches decisions]
      expected << "terminal_kind" if Archbuddy::Collect::Anonymizer.graph_schema_accepts_terminal_kind?
      expect(node.keys).to match_array(expected)
    end
  end

  # --- e. generic fallback (never-fabricate) -----------------------------------

  it "routes variable receivers and computed chains to the generic sink; no pair sink minted" do
    files = {
      "app.rb" => <<~RUBY
        class Caller
          def go
            client = build_client
            client.get("/x")
            Faraday.new.get("/y")
          end
        end
      RUBY
    }
    in_repo(files) do |dir|
      result = anonymize(dir)
      raw_symbols = result.id_map["ids"].map { |_i, d| d["symbol"] }
      # The inner literal `Faraday.new` is provable; the outer `.get` and the
      # variable receiver are NOT — they land on generic, minting nothing.
      expect(raw_symbols.grep(/\A<external/))
        .to contain_exactly("<external>", "<external:http:Faraday>")

      generic = id_for(result, "<external>")
      go_id   = id_for(result, "Caller#go")
      edge    = result.graph["edges"].find { |e| e["from"] == go_id && e["to"] == generic }
      expect(edge).not_to be_nil
      expect(edge["calls"]).to be >= 2 # build_client + client.get + chained .get
    end
  end

  # --- f. live engine graph-1.3 validation -------------------------------------

  it "produces a schema-valid graph with 4+ per-target sinks sharing terminal_kind values" do
    files = {
      "app.rb" => <<~RUBY
        class Caller
          def go
            Faraday.get("/x")
            Net::HTTP.start("h")
            GemA.one
            GemB.two
            GemC.three
          end
        end
      RUBY
    }
    in_repo(files) do |dir|
      graph = anonymize(dir).graph
      pair_sinks = graph["nodes"].select { |n| n["kind"] == "external" }
      expect(pair_sinks.length).to be >= 5 # 2 http + 3 gem + generic
      expect(ArchitectureAuditor::Contract::Validator.valid?(:graph, graph)).to be(true)
    end
  end
end
