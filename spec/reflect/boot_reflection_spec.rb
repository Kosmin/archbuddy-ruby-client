# frozen_string_literal: true

require "spec_helper"
require "archbuddy/reflect"

RSpec.describe Archbuddy::Reflect do
  describe Archbuddy::Reflect::Registry do
    it "detects Rails by config/environment.rb" do
      Dir.mktmpdir do |d|
        FileUtils.mkdir_p(File.join(d, "config"))
        File.write(File.join(d, "config", "environment.rb"), "")
        expect(described_class.for(d).key).to eq(:rails)
      end
    end

    it "detects Sinatra by the Gemfile gem plus an entry file" do
      Dir.mktmpdir do |d|
        File.write(File.join(d, "Gemfile"), %(source "x"\ngem "sinatra"\n))
        File.write(File.join(d, "app.rb"), "")
        expect(described_class.for(d).key).to eq(:sinatra)
      end
    end

    it "detects a packaged gem by its gemspec" do
      Dir.mktmpdir do |d|
        File.write(File.join(d, "thing.gemspec"), "")
        expect(described_class.for(d).key).to eq(:gem)
      end
    end

    it "falls back to require_glob for a plain project — never nil" do
      Dir.mktmpdir { |d| expect(described_class.for(d).key).to eq(:require_glob) }
    end

    it "lets explicit config OVERRIDE detection (detection is a convenience, not a mandate)" do
      Dir.mktmpdir do |d|
        FileUtils.mkdir_p(File.join(d, "config"))
        File.write(File.join(d, "config", "environment.rb"), "")
        expect(described_class.for(d).key).to eq(:rails)
        expect(described_class.for(d, config: { "boot" => "require_glob" }).key).to eq(:require_glob)
      end
    end

    it "raises on an unknown boot name rather than silently falling back" do
      Dir.mktmpdir do |d|
        expect { described_class.for(d, config: { "boot" => "nope" }) }
          .to raise_error(ArgumentError, /unknown reflect.boot/)
      end
    end

    it "treats a custom command as a strategy in its own right" do
      Dir.mktmpdir do |d|
        s = described_class.for(d, config: { "command" => "make boot" })
        expect(s.key).to eq(:custom)
        expect(s.spec(d)[:command]).to eq("make boot")
      end
    end
  end

  describe Archbuddy::Reflect::Merge do
    # `customer` and `customer=` are BOTH produced by attr_accessor; the spec then
    # also hand-writes `def customer=`. Same name, different origin — the case that
    # motivates classifying by ORIGIN rather than by name.
    let(:manifest) do
      { "methods" => [
        { "class" => "Order", "name" => "customer",   "scope" => "instance", "file" => "order.rb", "line" => 2 },
        { "class" => "Order", "name" => "customer=",  "scope" => "instance", "file" => "order.rb", "line" => 9 },
        { "class" => "Order", "name" => "line_items", "scope" => "instance", "file" => "gems/ar.rb", "line" => 40 },
        { "class" => "Order", "name" => "total",      "scope" => "instance", "file" => "order.rb", "line" => 12 },
        { "class" => "Order", "name" => "hashcode",   "scope" => "instance", "file" => nil, "line" => nil }
      ] }
    end
    # line 9 declares customer=, line 12 declares total. Line 2 declares NOTHING.
    let(:def_lines) { { "order.rb" => { 9 => ["customer="], 12 => ["total"] } } }
    let(:macros) do
      { "Order" => { "customer" => "attr_accessor", "customer=" => "attr_accessor",
                     "line_items" => "has_many" } }
    end
    let(:entries) { described_class.new(manifest, def_lines, macro_calls: macros).classify.to_h { |e| [e.name, e] } }

    it "keeps a HAND-WRITTEN writer as a real definition even though a macro makes the same name" do
      expect(entries["customer="].kind).to eq(:real_def)
      expect(entries["customer="].macro).to be_nil
    end

    it "classifies the macro-generated reader as trivial data access" do
      expect(entries["customer"].kind).to eq(:generated_trivial)
      expect(entries["customer"].macro).to eq("attr_accessor")
    end

    it "classifies a has_many product as a RELATION, not as trivial — it is a db exit" do
      expect(entries["line_items"].kind).to eq(:generated_relation)
    end

    it "captures a method whose definition site is INSIDE A GEM (the whole point)" do
      # source file is gems/ar.rb — outside the project. Filtering on definition
      # site would drop exactly the association methods we are here to find.
      expect(entries["line_items"].file).to eq("gems/ar.rb")
    end

    it "does not mistake a def-bearing line for a definition of a DIFFERENT name" do
      # line 2 carries no def at all; line 9/12 carry defs for other names.
      expect(entries["customer"].kind).not_to eq(:real_def)
    end

    it "records C-defined methods as :native rather than dropping them silently" do
      expect(entries["hashcode"].kind).to eq(:native)
    end

    it "summarises what reflection contributed" do
      expect(described_class.new(manifest, def_lines, macro_calls: macros).summary)
        .to include(real_def: 2, generated_trivial: 1, generated_relation: 1, native: 1)
    end
  end
end

require "archbuddy/collect/adapters/ruby/resolver"

RSpec.describe "reflection-driven resolution (R3.5)" do
  RESOLVER = Archbuddy::Collect::Adapters::Ruby::RubyResolver
  CTX = RESOLVER::CallContext

  # A table that knows NOTHING — so any resolution must come from reflection.
  let(:empty_table) do
    null_profile = Object.new
    def null_profile.respond_to_missing?(*) = true
    def null_profile.method_missing(name, *) = name.to_s.end_with?("?") ? false : nil
    Class.new do
      define_method(:profile) { null_profile }
      def method?(_) = false
      def active_record_class?(_) = false
    end.new
  end

  def fact(kind:, external_site: true)
    Archbuddy::Reflect::MethodTable::Fact.new(
      cls: "Order", name: "line_items", scope: "instance",
      file: "gems/ar.rb", line: 4, external_site: external_site, kind: kind, macro: "has_many"
    )
  end

  def table_with(f)
    Archbuddy::Reflect::MethodTable.new("Order" => { "line_items" => f })
  end

  def resolve(reflection)
    RESOLVER.new(empty_table, reflection: reflection)
            .resolve(CTX.new(name: "line_items", receiver: nil, enclosing_class: "Order",
                             table: empty_table, node: nil, type_scope: nil))
  end

  it "types a has_many product as a DATABASE crossing" do
    r = resolve(table_with(fact(kind: :generated_relation)))
    expect(r.tier).to eq(:reflect_self)
    expect(r.kind).to eq("db_op")
  end

  it "gives a gem-defined method the GENERIC exit category when the channel is unknown" do
    r = resolve(table_with(fact(kind: :generated_other)))
    expect(r.kind).to eq("external")
    expect(r.egress_category).to eq(:exit)
  end

  it "does NOT claim a crossing when the method is defined inside the project" do
    r = resolve(table_with(fact(kind: :real_def, external_site: false)))
    expect(r.tier.to_s).not_to start_with("reflect_")
  end

  it "behaves exactly as before when reflection did not run (enrichment, not prerequisite)" do
    r = resolve(nil)
    expect(r.tier.to_s).not_to start_with("reflect_")
  end

  it "resolves an ASSOCIATION through a TYPED receiver, not just self" do
    # `order.line_items` is a typed LOCAL receiver — the self tier can never see
    # it, which is why 69 relations produced zero db_op nodes before R4.7.
    table = Archbuddy::Reflect::MethodTable.new(
      "Order" => { "line_items" => Archbuddy::Reflect::MethodTable::Fact.new(
        cls: "Order", name: "line_items", scope: "instance", file: "gems/ar.rb",
        line: 4, external_site: true, kind: :generated_relation, macro: "has_many") }
    )
    typed = Class.new do
      define_method(:profile) { Object.new.tap { |o| def o.method_missing(n, *) = n.to_s.end_with?("?") ? false : nil
                                                     def o.respond_to_missing?(*) = true } }
      def method?(_) = false
      def active_record_class?(_) = false
    end.new
    r = RESOLVER.new(typed, reflection: table).resolve(
      CTX.new(name: "line_items", receiver: nil, enclosing_class: "Order",
              table: typed, node: nil, type_scope: nil))
    expect(r.kind).to eq("db_op")
  end

  it "emits only words the producer constant allows" do
    r = resolve(table_with(fact(kind: :generated_other)))
    expect(ArchitectureAuditor::Contract::TERMINAL_KINDS).to include(r.egress_category.to_s)
  end
end
