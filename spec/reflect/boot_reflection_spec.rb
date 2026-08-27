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
