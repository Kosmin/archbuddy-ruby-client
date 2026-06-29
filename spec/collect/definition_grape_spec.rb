# frozen_string_literal: true

require "prism"

# Unit coverage for Grape endpoint NODE minting in Pass 1 (W2). Drives the
# DefinitionPass directly over inline source and inspects the SymbolTable.
RSpec.describe Archbuddy::Collect::Adapters::Ruby::DefinitionPass do
  R = Archbuddy::Collect::Adapters::Ruby

  def table_for(src, rel_file: "app/api/api.rb")
    table = R::SymbolTable.new
    Prism.parse(src).value.accept(described_class.new(table, rel_file))
    table
  end

  it "mints one endpoint MethodEntry per verb-block, ordinal-stamped per verb" do
    table = table_for(<<~RUBY)
      module Api
        class Users < Grape::API
          get "/a" do
            1
          end
          get "/b" do
            2
          end
          post "/c" do
            3
          end
        end
      end
    RUBY

    endpoints = table.methods.values.select(&:endpoint).map(&:fq_symbol).sort
    expect(endpoints).to eq(
      ["Api::Users#GET[0]", "Api::Users#GET[1]", "Api::Users#POST[0]"]
    )
  end

  it "marks minted entries endpoint:true, instance-shaped, with the API as owner" do
    table = table_for(<<~RUBY)
      class Ping < Grape::API
        get "/ping" do
          pong
        end
      end
    RUBY

    entry = table.method_for("Ping#GET[0]")
    expect(entry).not_to be_nil
    expect(entry.endpoint).to be(true)
    expect(entry.singleton).to be(false)
    expect(entry.owner_fq).to eq("Ping")
    expect(entry.rel_file).to eq("app/api/api.rb")
  end

  it "captures branch/decision path-cost from the handler block body" do
    table = table_for(<<~RUBY)
      class Branchy < Grape::API
        get "/x" do
          do_thing if flag
          other_thing if flag2
        end
      end
    RUBY

    entry = table.method_for("Branchy#GET[0]")
    # two independent binary ifs => 2*2 = 4 paths, 2 decisions (matches BranchCounter)
    expect(entry.branches).to eq(4)
    expect(entry.decisions).to eq(2)
  end

  it "does NOT mint endpoints for verb calls outside a Grape::API class" do
    table = table_for(<<~RUBY)
      class NotGrape
        def setup
          get "/x" do
            noop
          end
        end
      end
    RUBY

    expect(table.methods.values.select(&:endpoint)).to be_empty
  end

  it "mints nothing for a Grape class with no endpoints (empty class)" do
    table = table_for(<<~RUBY)
      class Empty < Grape::API
      end
    RUBY

    expect(table.methods.values.select(&:endpoint)).to be_empty
    expect(table.class_for("Empty").grape_api?).to be(true)
  end

  it "leaves :endpoint false (default) for ordinary method defs" do
    table = table_for(<<~RUBY)
      class Plain
        def work
        end
      end
    RUBY

    expect(table.method_for("Plain#work").endpoint).to be(false)
  end
end
