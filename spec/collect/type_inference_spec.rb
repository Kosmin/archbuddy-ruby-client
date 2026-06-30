# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# v0.6 (L1): conservative, intra-procedural variable-receiver type inference.
# The resolver's R4.5 tier resolves variable / ivar / memoized-accessor /
# inline-`Const.new` receivers to REAL `Const#method` edges via the EXISTING
# SymbolTable#method? gate — emitting an edge ONLY when the method provably
# exists, declining to <external> otherwise (NEVER-FABRICATE). AR receivers
# mirror R4's db_op branch (x = User.new; x.where -> db_op, not a method edge).
RSpec.describe "Variable-receiver type inference (v0.6 L1 / R4.5)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def anonymize(root)
    Archbuddy::Collect::Anonymizer.new(
      Archbuddy::Collect::Registry.for("ruby").new(root, config).collect,
      tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  def in_repo(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, content|
        abs = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, content)
      end
      yield dir
    end
  end

  def id_for(result, sym)
    entry = result.id_map["ids"].find { |_i, d| d["symbol"] == sym }
    entry&.first
  end

  # Kind of the node behind a real symbol (via the id-map), or nil.
  def kind_for(result, sym)
    id = id_for(result, sym)
    return nil unless id

    result.graph["nodes"].find { |n| n["id"] == id }&.fetch("kind", nil)
  end

  # True iff a directed edge from_sym -> to_sym exists in the graph.
  def edge?(result, from_sym, to_sym)
    from_id = id_for(result, from_sym)
    to_id   = id_for(result, to_sym)
    return false unless from_id && to_id

    result.graph["edges"].any? { |e| e["from"] == from_id && e["to"] == to_id }
  end

  # Real target symbols of every edge FROM from_sym.
  def edge_targets(result, from_sym)
    from_id = id_for(result, from_sym)
    return [] unless from_id

    result.graph["edges"].filter_map do |e|
      next unless e["from"] == from_id

      result.id_map["ids"].dig(e["to"], "symbol")
    end
  end

  # --- Case 1: memoized accessor -------------------------------------------

  it "resolves a bare memoized-accessor receiver to Const#method (the dominant nexus pattern)" do
    in_repo(
      "app/services/widget.rb" => <<~RUBY,
        class Widget
          def render
            42
          end
        end
      RUBY
      "app/services/page.rb" => <<~RUBY
        class Page
          def show
            widget.render               # bare accessor -> Widget#render via @widget memoize
          end

          def widget
            @widget ||= Widget.new      # memoized accessor (||= OrWrite)
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      expect(edge?(result, "Page#show", "Widget#render")).to be(true),
        "expected Page#show -> Widget#render via the memoized accessor type"
    end
  end

  # --- Case 1b: memoized accessor whose body is a begin/rescue (BeginNode) -
  # Regression for the V1-validation crash (M-C4): a `def` whose body carries a
  # `rescue`/`ensure` parses as a Prism::BeginNode (statements under `.statements`,
  # NOT `.body`). The scanner must descend into it, resolve the accessor, and NOT
  # raise `NoMethodError: undefined method 'body' for Prism::BeginNode`.
  it "resolves a memoized accessor whose body is wrapped in begin/rescue (BeginNode)" do
    in_repo(
      "app/services/widget.rb" => <<~RUBY,
        class Widget
          def render
            42
          end
        end
      RUBY
      "app/services/page.rb" => <<~RUBY
        class Page
          def show
            widget.render               # bare accessor -> Widget#render
          end

          def widget                    # body is a BeginNode (rescue clause)
            @widget ||= Widget.new      # memoized accessor inside begin/rescue
          rescue StandardError
            nil
          end
        end
      RUBY
    ) do |dir|
      expect { anonymize(dir) }.not_to raise_error
      result = anonymize(dir)
      expect(edge?(result, "Page#show", "Widget#render")).to be(true),
        "expected the rescue-wrapped memoized accessor to still resolve to Widget#render"
    end
  end

  # --- Case 2: inline new-chains (plain + namespaced) ----------------------

  it "resolves inline Const.new.method AND namespaced Const::Path.new.method chains" do
    in_repo(
      "app/services/mailer.rb" => <<~RUBY,
        class Mailer
          def deliver
            true
          end
        end
      RUBY
      "app/clients/snowflake/client.rb" => <<~RUBY,
        module Snowflake
          class Client
            def query
              []
            end
          end
        end
      RUBY
      "app/services/dispatch.rb" => <<~RUBY
        class Dispatch
          def go
            Mailer.new.deliver                  # inline Const.new.method
            Snowflake::Client.new.query         # inline Const::Path.new.method
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      expect(edge?(result, "Dispatch#go", "Mailer#deliver")).to be(true),
        "expected Dispatch#go -> Mailer#deliver (inline Const.new chain)"
      expect(edge?(result, "Dispatch#go", "Snowflake::Client#query")).to be(true),
        "expected Dispatch#go -> Snowflake::Client#query (namespaced inline chain)"
    end
  end

  # --- Case 3: intra-method local ------------------------------------------

  it "resolves an intra-method local assigned from Const.new" do
    in_repo(
      "app/services/engine.rb" => <<~RUBY,
        class Engine
          def run
            :ok
          end
        end
      RUBY
      "app/services/job.rb" => <<~RUBY
        class Job
          def perform
            x = Engine.new            # local typed to Engine
            x.run                     # x.run -> Engine#run
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      expect(edge?(result, "Job#perform", "Engine#run")).to be(true),
        "expected Job#perform -> Engine#run (intra-method local type)"
    end
  end

  # --- Case 4: NEVER-FABRICATE declines ------------------------------------

  it "declines a param receiver (no provable type) — NO fabricated edge" do
    in_repo(
      "app/services/runner.rb" => <<~RUBY
        class Runner
          def go(dep)
            dep.method                # param receiver -> unknown type -> <external>
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      fabricated = edge_targets(result, "Runner#go").select { |s| s&.end_with?("#method") }
      expect(fabricated).to be_empty,
        "fabricated a #method edge from a param receiver: #{fabricated.inspect}"
    end
  end

  it "declines an externally-returned receiver (RHS not Const.new) — NO fabricated edge" do
    in_repo(
      "app/services/factory.rb" => <<~RUBY
        class Factory
          def make
            x = build_it              # build_it is a non-Const.new call -> x untyped
            x.run                     # -> <external>, no fabricated #run edge
          end

          def build_it
            Object.new
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      fabricated = edge_targets(result, "Factory#make").select { |s| s&.end_with?("#run") }
      expect(fabricated).to be_empty,
        "fabricated a #run edge from an externally-returned receiver: #{fabricated.inspect}"
    end
  end

  it "declines when the inferred Const#method is NOT captured — NO node, NO edge" do
    in_repo(
      "app/services/thing.rb" => <<~RUBY,
        class Thing
          # defines no #absent_method
        end
      RUBY
      "app/services/caller.rb" => <<~RUBY
        class Caller
          def go
            Thing.new.absent_method   # type known, but #absent_method not in the table
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      expect(id_for(result, "Thing#absent_method")).to be_nil,
        "fabricated a node for an uncaptured method"
      fabricated = edge_targets(result, "Caller#go").select { |s| s&.include?("absent_method") }
      expect(fabricated).to be_empty,
        "fabricated an edge to an uncaptured method: #{fabricated.inspect}"
    end
  end

  # --- Case 5: AR mirror ----------------------------------------------------

  it "resolves a tracked AR instance method to a db_op node, NOT a fabricated method edge" do
    in_repo(
      "app/models/user.rb" => <<~RUBY,
        class User < ApplicationRecord
        end
      RUBY
      "app/services/lookup.rb" => <<~RUBY
        class Lookup
          def go
            x = User.new              # tracked AR instance
            x.where(active: true)     # AR method on a tracked AR type -> db_op
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      # A db_op node keyed User.where exists.
      expect(kind_for(result, "User.where")).to eq("db_op"),
        "expected a User.where db_op node"
      expect(edge?(result, "Lookup#go", "User.where")).to be(true),
        "expected Lookup#go -> User.where db_op edge"
      # NO fabricated method edge to a User#where / User.where method node.
      expect(id_for(result, "User#where")).to be_nil,
        "fabricated a User#where method node for an AR receiver"
    end
  end
end
