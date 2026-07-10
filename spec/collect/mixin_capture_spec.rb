# frozen_string_literal: true

require "prism"

# Unit coverage for L14 GENERAL mixin capture (v0.10 W0). Drives the
# DefinitionPass directly over inline source (mirror definition_grape_spec)
# and inspects ClassEntry#mixins + SymbolTable#chain_any_module?.
RSpec.describe Archbuddy::Collect::Adapters::Ruby::DefinitionPass, "mixin capture (L14)" do
  RM = Archbuddy::Collect::Adapters::Ruby

  def table_for(src, rel_file: "app/models/foo.rb")
    table = RM::SymbolTable.new
    Prism.parse(src).value.accept(described_class.new(table, rel_file))
    table
  end

  it "captures literal include / prepend / extend into ClassEntry#mixins in source order" do
    table = table_for(<<~RUBY)
      class Foo
        include Bar
        prepend Baz
        extend Helpers
      end
    RUBY

    expect(table.class_for("Foo").mixins).to eq(%w[Bar Baz Helpers])
  end

  it "captures multi-argument and namespaced constant mixins" do
    table = table_for(<<~RUBY)
      class Foo
        include Alpha, Beta
        include Concerns::Trackable
      end
    RUBY

    expect(table.class_for("Foo").mixins).to eq(%w[Alpha Beta Concerns::Trackable])
  end

  it "captures mixins declared inside modules too (modules are registered entries)" do
    table = table_for(<<~RUBY)
      module Jobs
        module Retryable
          include Sidekiq::Job
        end
      end
    RUBY

    expect(table.class_for("Jobs::Retryable").mixins).to eq(["Sidekiq::Job"])
  end

  it "declines every dynamic mixin argument (variable / call / splat / conditional expr)" do
    table = table_for(<<~RUBY)
      class Foo
        include some_var
        include mod_from_method()
        include(*mods)
        include(flag ? A : B)
      end
    RUBY

    expect(table.class_for("Foo").mixins).to eq([])
  end

  it "records the literal constant but skips the dynamic sibling in a mixed argument list" do
    table = table_for(<<~RUBY)
      class Foo
        include Bar, some_var
      end
    RUBY

    expect(table.class_for("Foo").mixins).to eq(["Bar"])
  end

  it "declines non-self receivers and non-constant idioms (Foo.include / extend self)" do
    table = table_for(<<~RUBY)
      class Other
        Foo.include Bar
        extend self
      end
    RUBY

    expect(table.class_for("Other").mixins).to eq([])
  end

  it "ignores a top-level include (no enclosing class) without fabricating an entry" do
    table = table_for(<<~RUBY)
      include GlobalThing

      class Foo
      end
    RUBY

    expect(table.class_for("Foo").mixins).to eq([])
    expect(table.classes.keys).to eq(["Foo"])
  end

  it "defaults mixins to [] for a class with no mixin declarations" do
    table = table_for("class Plain; end")

    expect(table.class_for("Plain").mixins).to eq([])
  end

  it "accumulates mixins across reopened class bodies onto the first-wins entry" do
    table = table_for(<<~RUBY)
      class Foo
        include Bar
      end

      class Foo
        include Baz
      end
    RUBY

    expect(table.class_for("Foo").mixins).to eq(%w[Bar Baz])
  end

  describe "#chain_any_module?" do
    it "finds a mixin on the class itself" do
      table = table_for(<<~RUBY)
        class Job
          include Sidekiq::Job
        end
      RUBY

      expect(table.chain_any_module?("Job") { |m| m == "Sidekiq::Job" }).to be(true)
    end

    it "inherits a base-class mixin via the superclass chain" do
      table = table_for(<<~RUBY)
        class Base
          include M
        end

        class Sub < Base
        end
      RUBY

      expect(table.chain_any_module?("Sub") { |m| m == "M" }).to be(true)
    end

    it "is false when no mixin in the chain matches" do
      table = table_for(<<~RUBY)
        class Base
          include M
        end

        class Sub < Base
        end
      RUBY

      expect(table.chain_any_module?("Sub") { |m| m == "Nope" }).to be(false)
    end

    it "is false for an unknown fq (never fabricated), mirroring chain_any?" do
      table = table_for("class Foo; end")

      expect(table.chain_any_module?("Ghost") { |_m| true }).to be(false)
    end
  end

  it "leaves superclass detection untouched (active_record?/controller? unchanged)" do
    table = table_for(<<~RUBY)
      class Widget < ApplicationRecord
        include Concerns::Trackable
      end

      class WidgetsController < ApplicationController
      end
    RUBY

    expect(table.active_record_class?("Widget")).to be(true)
    expect(table.controller_class?("WidgetsController")).to be(true)
    expect(table.class_for("Widget").superclass).to eq("ApplicationRecord")
    expect(table.class_for("Widget").mixins).to eq(["Concerns::Trackable"])
  end
end
