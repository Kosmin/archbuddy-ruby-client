# frozen_string_literal: true

require "tmpdir"

# v0.10 W1-D (L21): R1 narrowing + coverage tallies. R1 flags a meta verb
# ONLY when the call is DYNAMIC (non-literal first arg); a literal
# send/public_send/__send__ falls through to the MetaSendProbe (R5), which
# resolves it gated on table.method? or declines to `<external>`. The
# always-dynamic verbs (eval/*_eval/define_method/method_missing/const_get/
# instance_exec) stay flagged unconditionally. The Accumulator promotes the
# honesty signal to a coverage tuple {meta_sites, meta_resolved,
# total_call_sites} surfaced via AdapterResult#diagnostics.
RSpec.describe "Metaprogramming resolution (W1-D: narrowed R1 + coverage)" do
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

  def edge_exists?(result, from_sym, to_sym)
    id_for = ->(sym) { result.id_map["ids"].find { |_i, d| d["symbol"] == sym }&.first }
    from_id = id_for.call(from_sym)
    to_id   = id_for.call(to_sym)
    return false if from_id.nil? || to_id.nil?

    result.graph["edges"].any? { |e| e["from"] == from_id && e["to"] == to_id }
  end

  describe "Vocab.meta_resolvable? (the resolvable-literal bucket)" do
    let(:vocab) { Archbuddy::Collect::Adapters::Ruby::Vocab }

    it "holds the literal-dispatch verbs incl. try/try!" do
      %w[send public_send __send__ try try!].each do |verb|
        expect(vocab.meta_resolvable?(verb)).to be(true)
      end
      expect(vocab.meta_resolvable?("foo")).to be(false)
    end

    it "keeps try/try! OUT of the always-dynamic METAPROGRAMMING set" do
      expect(vocab.metaprogramming?("try")).to be(false)
      expect(vocab.metaprogramming?("try!")).to be(false)
      expect(vocab.metaprogramming?("eval")).to be(true)   # unchanged
      expect(vocab.metaprogramming?("send")).to be(true)   # still meta when dynamic
    end
  end

  it "resolves a literal send to an in-tree method (edge, NOT flagged)" do
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
      expect(collect(dir).diagnostics[:meta_sites_skipped]).to eq(0)
      expect(edge_exists?(anonymize(dir), "Dispatcher#run", "Dispatcher#work")).to be(true)
    end
  end

  it "declines a literal send to an UNKNOWN target -> <external>, still unflagged" do
    source = <<~RUBY
      class Dispatcher
        def run
          send(:vanished)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:meta_sites_skipped]).to eq(0)
      expect(result.diagnostics[:probe_edges].fetch(:meta_send, 0)).to eq(0)
      anon = anonymize(dir)
      # No fabricated target node (I1); the call routes to the shared sink.
      expect(anon.id_map["ids"].any? { |_i, d| d["symbol"] == "Dispatcher#vanished" }).to be(false)
      expect(anon.id_map["ids"].any? { |_i, d| d["symbol"] == "<external>" }).to be(true)
    end
  end

  it "still flags a DYNAMIC send (variable arg) as a blind spot with no edge" do
    source = <<~RUBY
      class Dispatcher
        def run(name)
          send(name)
        end

        def work
          1
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:meta_sites_skipped]).to eq(1)
      expect(edge_exists?(anonymize(dir), "Dispatcher#run", "Dispatcher#work")).to be(false)
    end
  end

  it "no longer mis-flags a domain class's OWN def send/try called with a literal" do
    # The latent name-before-receiver FP: R1 used to flag ANY call named
    # send/try before looking at the receiver or table. A domain `def send`
    # invoked with a literal arg now resolves through the normal tiers.
    source = <<~RUBY
      class Mailer
        def send(what)
          what
        end

        def try(what)
          what
        end
      end

      class Caller
        def go
          m = Mailer.new
          m.send(:welcome)
          m.try(:welcome)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:meta_sites_skipped]).to eq(0)
      anon = anonymize(dir)
      # Resolves to the domain's own methods (typed receiver, R4.5) — the
      # true call targets — not to a metaprogramming flag.
      expect(edge_exists?(anon, "Caller#go", "Mailer#send")).to be(true)
      expect(edge_exists?(anon, "Caller#go", "Mailer#try")).to be(true)
    end
  end

  it "keeps eval / define_method / instance_exec ALWAYS flagged (literal or not)" do
    source = <<~RUBY
      class Meta
        def run(name)
          eval("1 + 1")
          define_method(:foo) { 1 }
          instance_exec { 2 }
        end
      end
    RUBY
    in_repo(source) do |dir|
      expect(collect(dir).diagnostics[:meta_sites_skipped]).to eq(3)
    end
  end

  describe "coverage tallies (the committed-metric producers)" do
    it "counts {flagged, resolved, total} per the Task-4 fixture" do
      # 1 dynamic send + 1 resolved literal send + 3 ordinary calls = 5 sites.
      source = <<~RUBY
        class Worker
          def run(name)
            send(name)     # 1: dynamic -> flagged
            send(:step)    # 2: literal -> meta_send edge
            step           # 3: ordinary in-tree call
            helper         # 4: ordinary in-tree call
            Missing.other  # 5: ordinary unresolved call -> <external>
          end

          def step
            1
          end

          def helper
            2
          end
        end
      RUBY
      in_repo(source) do |dir|
        d = collect(dir).diagnostics
        expect(d[:meta_sites_skipped]).to eq(1)
        expect(d[:meta_resolved]).to eq(1)
        expect(d[:total_call_sites]).to eq(5)
      end
    end

    it "reports honest zeros on a fixture with no calls at all" do
      source = <<~RUBY
        class Empty
          def noop
          end
        end
      RUBY
      in_repo(source) do |dir|
        d = collect(dir).diagnostics
        expect(d[:meta_sites_skipped]).to eq(0)
        expect(d[:meta_resolved]).to eq(0)
        expect(d[:total_call_sites]).to eq(0)
      end
    end

    it "does not change db_op / probe_edges accounting for meta-free fixtures" do
      source = <<~RUBY
        class Invoice < ApplicationRecord
          def self.recent
            where(created_at: 1)
          end
        end
      RUBY
      in_repo(source) do |dir|
        d = collect(dir).diagnostics
        expect(d[:probe_edges].fetch(:meta_send, 0)).to eq(0)
        expect(d[:total_call_sites]).to eq(1) # the where() db_op site
      end
    end
  end
end
