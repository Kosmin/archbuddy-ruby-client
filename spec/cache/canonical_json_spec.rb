# frozen_string_literal: true

require "archbuddy/cache"

RSpec.describe Archbuddy::Cache::CanonicalJson do
  subject(:mod) { described_class }

  it "sorts object keys recursively at every level" do
    out = mod.dump({ "b" => 1, "a" => { "z" => 1, "y" => 2 } })
    expect(out).to eq(%({"a":{"y":2,"z":1},"b":1}\n))
  end

  it "preserves array order (the caller imposes canonical array ordering)" do
    expect(mod.dump([3, 1, 2])).to eq("[3,1,2]\n")
  end

  it "emits exactly one trailing newline (stable POSIX text diff)" do
    expect(mod.dump({ "a" => 1 })).to end_with("}\n")
    expect(mod.dump({ "a" => 1 }).scan("\n").length).to eq(1)
  end

  it "rounds floats to fixed precision so re-runs don't jitter" do
    expect(mod.dump({ "x" => 0.1 + 0.2 })).to eq(%({"x":0.3}\n))
  end

  it "keeps an integral float as a float (type stable)" do
    expect(mod.dump({ "score" => 2.0 })).to eq(%({"score":2.0}\n))
  end

  it "is idempotent: dumping twice yields identical bytes" do
    doc = { "b" => [2.00000001, 1.0], "a" => { "n" => 3 } }
    expect(mod.dump(doc)).to eq(mod.dump(doc))
  end

  it "refuses to serialize a non-finite float (never emit non-portable JSON)" do
    expect { mod.dump({ "x" => (1.0 / 0.0) }) }.to raise_error(ArgumentError, /non-finite/)
  end
end
