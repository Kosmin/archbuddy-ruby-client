# frozen_string_literal: true

require "prism"

RSpec.describe Archbuddy::Collect::Adapters::Ruby::DbOpSpec do
  # Parse a single AR call expression and hand the CallNode to for_call.
  def spec_for(src)
    node = Prism.parse(src).value.statements.body.first
    described_class.for_call(node)
  end

  describe ".for_call op_kind classification (V4/P4)" do
    {
      "where(state: 1)"        => "read",
      "all"                    => "read",
      "find(1)"                => "read",
      "count"                  => "read",
      "update(name: x)"        => "write",
      "create(name: x)"        => "write",
      "save!"                  => "write",
      "touch"                  => "write",
      "destroy"                => "destroy",
      "delete_all"             => "destroy"
    }.each do |src, op_kind|
      it "classifies #{src.inspect} as #{op_kind}" do
        expect(spec_for(src).op_kind).to eq(op_kind)
      end
    end
  end

  describe ".for_call write specificity (V4/P4)" do
    it "treats a symbol-keyed literal hash write as specific (sink_open false)" do
      spec = spec_for("update(name: x, email: y)")
      expect(spec.specificity).to eq("specific")
      expect(spec.open_ended_write?).to be(false)
    end

    it "treats bare-symbol field writes as specific (update_columns(:a, :b))" do
      spec = spec_for("update_columns(:a, :b, :c)")
      expect(spec.specificity).to eq("specific")
      expect(spec.open_ended_write?).to be(false)
    end

    it "treats a variable-hash write as open_ended (sink_open true)" do
      spec = spec_for("update(attrs)")
      expect(spec.specificity).to eq("open_ended")
      expect(spec.open_ended_write?).to be(true)
    end

    it "treats a **splat in the hash as open_ended" do
      spec = spec_for("update(name: x, **o)")
      expect(spec.specificity).to eq("open_ended")
      expect(spec.open_ended_write?).to be(true)
    end

    it "treats a string-SQL write as open_ended (update_all(\"status='x'\"))" do
      spec = spec_for("update_all(\"status='x'\")")
      expect(spec.specificity).to eq("open_ended")
      expect(spec.open_ended_write?).to be(true)
    end
  end

  describe ".for_call non-field-write / non-write (specificity n/a)" do
    it "returns nil specificity for reads (factor 1)" do
      spec = spec_for("where(state: 1)")
      expect(spec.specificity).to be_nil
      expect(spec.open_ended_write?).to be(false)
    end

    it "returns nil specificity for destroys (factor 1)" do
      spec = spec_for("destroy")
      expect(spec.specificity).to be_nil
      expect(spec.open_ended_write?).to be(false)
    end

    it "returns nil specificity for save! (no inspectable field payload)" do
      spec = spec_for("save!")
      expect(spec.specificity).to be_nil
      expect(spec.open_ended_write?).to be(false)
    end
  end
end
