# frozen_string_literal: true

require "tmpdir"

# END-TO-END Sidekiq / ActiveJob DISPATCH probe (W3). Feeds inline source
# through the REAL adapter + Anonymizer and asserts that an async dispatch
# (`Const.perform_async|perform_later|perform_in|perform_at`, incl. a single
# `.set(...)` hop) resolves to a single `caller -> Const#perform` edge IFF
# `Const#perform` is a known method node — and DECLINES to the shared
# <external> sink when the target is absent / the receiver is not a constant.
# Provenance rides diagnostics[:probe_edges][:sidekiq_dispatch] only, never the
# serialized graph.
RSpec.describe "Sidekiq/ActiveJob dispatch probe (W3 e2e)" do
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

  # A job with a real #perform plus a caller that dispatches it.
  def job_and_caller(dispatch_expr)
    <<~RUBY
      class SomeJob < ApplicationJob
        def perform(x)
          x
        end
      end

      class Caller
        def go
          #{dispatch_expr}
        end
      end
    RUBY
  end

  def edge_exists?(result, from_sym, to_sym)
    id_for = ->(sym) { result.id_map["ids"].find { |_i, d| d["symbol"] == sym }&.first }
    from_id = id_for.call(from_sym)
    to_id   = id_for.call(to_sym)
    return false if from_id.nil? || to_id.nil?

    result.graph["edges"].any? { |e| e["from"] == from_id && e["to"] == to_id }
  end

  def external_id(result)
    result.id_map["ids"].find { |_i, d| d["symbol"] == "<external>" }&.first
  end

  %w[perform_async perform_later].each do |verb|
    it "resolves Const.#{verb} to a single Caller#go -> SomeJob#perform edge" do
      in_repo(job_and_caller("SomeJob.#{verb}(1)")) do |dir|
        result = anonymize(dir)
        expect(edge_exists?(result, "Caller#go", "SomeJob#perform")).to be(true)

        # REPLACE-not-stack (P6): the dispatch site is NOT also an <external> edge.
        id_for = ->(sym) { result.id_map["ids"].find { |_i, d| d["symbol"] == sym }&.first }
        go_id  = id_for.call("Caller#go")
        ext_id = external_id(result)
        ext_edge = result.graph["edges"].find { |e| e["from"] == go_id && e["to"] == ext_id }
        expect(ext_edge).to be_nil
      end
    end
  end

  it "resolves perform_in(5.minutes, ...) and perform_at(t, ...)" do
    %w[perform_in perform_at].each do |verb|
      in_repo(job_and_caller("SomeJob.#{verb}(5, 1)")) do |dir|
        result = anonymize(dir)
        expect(edge_exists?(result, "Caller#go", "SomeJob#perform"))
          .to be(true), "expected #{verb} to resolve to SomeJob#perform"
      end
    end
  end

  it "resolves a single Const.set(...).perform_later hop to SomeJob#perform" do
    in_repo(job_and_caller("SomeJob.set(wait: 5).perform_later(1)")) do |dir|
      result = anonymize(dir)
      expect(edge_exists?(result, "Caller#go", "SomeJob#perform")).to be(true)
    end
  end

  it "declines (-> <external>) when the dispatched const has no #perform node" do
    source = <<~RUBY
      class Caller
        def go
          NoPerformJob.perform_later(1)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = anonymize(dir)
      # No fabricated #perform node.
      expect(result.id_map["ids"].any? { |_i, d| d["symbol"] == "NoPerformJob#perform" }).to be(false)
      # The call resolves to the shared external sink instead.
      id_for = ->(sym) { result.id_map["ids"].find { |_i, d| d["symbol"] == sym }&.first }
      go_id  = id_for.call("Caller#go")
      ext_id = external_id(result)
      expect(ext_id).not_to be_nil
      ext_edge = result.graph["edges"].find { |e| e["from"] == go_id && e["to"] == ext_id }
      expect(ext_edge).not_to be_nil
    end
  end

  it "declines for a non-constant receiver (SomeWrapper.new.perform_later)" do
    source = <<~RUBY
      class SomeWrapper
        def perform(x)
          x
        end
      end

      class Caller
        def go
          SomeWrapper.new.perform_later(1)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = anonymize(dir)
      # The probe must NOT fabricate a SomeWrapper#perform edge from this site.
      expect(edge_exists?(result, "Caller#go", "SomeWrapper#perform")).to be(false)
    end
  end

  it "does NOT match bare perform / perform_now (handled by base R4, not the probe)" do
    source = <<~RUBY
      class SomeJob < ApplicationJob
        def perform(x)
          x
        end
      end

      class Caller
        def go
          SomeJob.perform_now(1)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = collect(dir)
      # No dispatch-probe edge tallied for perform_now.
      expect(result.diagnostics[:probe_edges].fetch(:sidekiq_dispatch, 0)).to eq(0)
    end
  end

  it "tallies resolved dispatch edges in diagnostics[:probe_edges][:sidekiq_dispatch]" do
    source = <<~RUBY
      class SomeJob < ApplicationJob
        def perform(x)
          x
        end
      end

      class Caller
        def go
          SomeJob.perform_async(1)
          SomeJob.set(wait: 5).perform_later(2)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:probe_edges][:sidekiq_dispatch]).to eq(2)
    end
  end

  it "reports zero / absent tally when no dispatch resolves" do
    source = <<~RUBY
      class Caller
        def go
          NoPerformJob.perform_later(1)
        end
      end
    RUBY
    in_repo(source) do |dir|
      result = collect(dir)
      expect(result.diagnostics[:probe_edges].fetch(:sidekiq_dispatch, 0)).to eq(0)
    end
  end

  it "keeps the probe tally OUT of the serialized graph" do
    in_repo(job_and_caller("SomeJob.perform_async(1)")) do |dir|
      anon = anonymize(dir)
      serialized = ArchitectureAuditor::Contract::Serializer.dump(anon.graph)
      expect(serialized).not_to include("probe_edges")
      expect(serialized).not_to include("sidekiq_dispatch")
      expect(serialized).not_to include("provenance")
      expect(anon.graph).not_to have_key("diagnostics")
    end
  end

  it "produces a graph that validates against the engine's graph schema" do
    in_repo(job_and_caller("SomeJob.perform_async(1)")) do |dir|
      graph = anonymize(dir).graph
      expect {
        ArchitectureAuditor::Contract::Validator.validate!(:graph, graph)
      }.not_to raise_error
    end
  end
end
