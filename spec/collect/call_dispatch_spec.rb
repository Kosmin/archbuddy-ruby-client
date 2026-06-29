# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# v0.5: `.call` is no longer in OPERATOR_DENY, so the EXISTING R4 const-receiver
# tier resolves service-object / interactor dispatch (`SomeInteractor.call`) to
# the captured instance `#call` body — a real, provable edge — while the
# proc/lambda case (variable receiver) still falls through to <external> with no
# fabricated edge. This is the never-fabricate guarantee, enforced by R4's
# constant-receiver + table.method? gate (NOT a bespoke probe / not a heuristic).
RSpec.describe "Service-object / interactor .call dispatch resolution (v0.5)" do
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

  # True iff a directed edge from_sym -> to_sym exists in the graph.
  def edge?(result, from_sym, to_sym)
    from_id = id_for(result, from_sym)
    to_id   = id_for(result, to_sym)
    return false unless from_id && to_id

    result.graph["edges"].any? { |e| e["from"] == from_id && e["to"] == to_id }
  end

  it "resolves a constant-receiver .call to the captured instance #call (interactor/service dispatch)" do
    in_repo(
      "app/controllers/orders_controller.rb" => <<~RUBY,
        class OrdersController < ApplicationController
          def create
            OrderingMerchant::Update.call(params)   # const receiver -> R4 const-instance
          end
        end
      RUBY
      "app/interactors/ordering_merchant/update.rb" => <<~RUBY
        module OrderingMerchant
          class Update
            def call
              Order.create!(state: "x")
            end
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      expect(edge?(result, "OrdersController#create", "OrderingMerchant::Update#call")).to be(true),
        "expected OrdersController#create -> OrderingMerchant::Update#call (the interactor body)"
    end
  end

  it "does NOT fabricate an edge for a variable/proc receiver .call (never-fabricate)" do
    in_repo(
      "app/services/runner.rb" => <<~RUBY
        class Runner
          def go(callback)
            callback.call         # variable receiver -> NOT a constant -> no edge, stays <external>
            handler = ->(x) { x } # local proc
            handler.call(1)       # variable receiver -> no edge
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      # No edge whose target symbol ends in "#call" was fabricated from a variable receiver.
      call_targets = result.graph["edges"].filter_map do |e|
        sym = result.id_map["ids"].dig(e["to"], "symbol")
        sym if sym&.end_with?("#call")
      end
      expect(call_targets).to be_empty,
        "fabricated a #call edge from a variable/proc receiver: #{call_targets.inspect}"
    end
  end

  it "declines a constant-receiver .call when the target #call is NOT a captured method (e.g. an Organizer with no own #call)" do
    in_repo(
      "app/controllers/things_controller.rb" => <<~RUBY,
        class ThingsController < ApplicationController
          def index
            Some::Organizer.call(params)   # const receiver, but Organizer defines no #call body
          end
        end
      RUBY
      "app/interactors/some/organizer.rb" => <<~RUBY
        module Some
          class Organizer
            # organize A, B, C  (no instance #call defined here)
          end
        end
      RUBY
    ) do |dir|
      result = anonymize(dir)
      # No fabricated edge to Some::Organizer#call (it isn't a captured method).
      expect(id_for(result, "Some::Organizer#call")).to be_nil
    end
  end
end
