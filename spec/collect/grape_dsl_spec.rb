# frozen_string_literal: true

require "prism"

# Unit coverage for the shared Grape recognizer (W2). Pure predicate functions
# over Prism nodes — the single source of truth both passes consult so their
# endpoint detection and minted FQ agree (F5).
RSpec.describe Archbuddy::Collect::Adapters::Ruby::GrapeDsl do
  GD = Archbuddy::Collect::Adapters::Ruby::GrapeDsl

  # First statement of `src` parsed to a Prism node.
  def node(src)
    Prism.parse(src).value.statements.body.first
  end

  describe ".grape_api_superclass?" do
    it "is true for Grape::API and Grape::API::Instance" do
      expect(GD.grape_api_superclass?("Grape::API")).to be(true)
      expect(GD.grape_api_superclass?("Grape::API::Instance")).to be(true)
    end

    it "is false for non-Grape superclasses and nil/empty" do
      expect(GD.grape_api_superclass?("ApplicationController")).to be(false)
      expect(GD.grape_api_superclass?(nil)).to be(false)
      expect(GD.grape_api_superclass?("")).to be(false)
    end
  end

  describe ".endpoint_verb_call?" do
    it "is true for a self/implicit-receiver verb call carrying a block" do
      %w[get post put patch delete].each do |verb|
        expect(GD.endpoint_verb_call?(node("#{verb} '/x' do; end"))).to be(true)
      end
    end

    it "is false for a verb call WITHOUT a block" do
      expect(GD.endpoint_verb_call?(node("get '/x'"))).to be(false)
    end

    it "is false for a verb call on an explicit non-self receiver" do
      expect(GD.endpoint_verb_call?(node("client.get('/x') { }"))).to be(false)
    end

    it "is false for a non-verb method name and for non-call nodes" do
      expect(GD.endpoint_verb_call?(node("resource '/x' do; end"))).to be(false)
      expect(GD.endpoint_verb_call?(node("x = 1"))).to be(false)
    end
  end

  describe ".mount_call? / .helpers_block_call?" do
    it "recognizes a self-receiver mount call" do
      expect(GD.mount_call?(node("mount Foo::API"))).to be(true)
      expect(GD.mount_call?(node("get '/x'"))).to be(false)
    end

    it "recognizes a helpers block" do
      expect(GD.helpers_block_call?(node("helpers do; end"))).to be(true)
      expect(GD.helpers_block_call?(node("helpers"))).to be(false)
    end
  end

  describe ".endpoint_fq" do
    it "renders a stable, ordinal-stamped endpoint symbol" do
      expect(GD.endpoint_fq("Api::Users", "get", 0)).to eq("Api::Users#GET[0]")
      expect(GD.endpoint_fq("Api::Users", :post, 2)).to eq("Api::Users#POST[2]")
    end
  end
end
