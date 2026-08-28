# frozen_string_literal: true

require "spec_helper"
require "archbuddy/reflect"
require "archbuddy/collect/adapters/ruby/symbol_table"
require "archbuddy/collect/adapters/ruby/generated_nodes"

RSpec.describe Archbuddy::Collect::Adapters::Ruby::GeneratedNodes do
  # Not a top-level constant: `ST` is generic enough to collide with another
  # spec file loaded into the same process.
  def st = Archbuddy::Collect::Adapters::Ruby::SymbolTable

  def table_with(classes: %w[Order], methods: [])
    t = st.new
    classes.each { |c| t.add_class(st::ClassEntry.new(fq_name: c, rel_file: "app/#{c.downcase}.rb", line: 1)) }
    methods.each do |fq|
      owner, name = fq.split("#")
      t.add_method(st::MethodEntry.new(fq_symbol: fq, owner_fq: owner, name: name, rel_file: "app/x.rb", line: 2))
    end
    t
  end

  def reflection(*entries)
    Archbuddy::Reflect::MethodTable.from_manifest({ "methods" => entries })
  end

  def m(cls, name, owner: cls, app_site: true, file: "app/order.rb", line: 3)
    { "class" => cls, "name" => name, "owner" => owner, "scope" => "instance",
      "app_site" => app_site, "file" => file, "line" => line }
  end

  def forwarding(manifest_methods, delegations: {})
    Archbuddy::Reflect::Forwarding.from({ "methods" => manifest_methods }, delegations: delegations)
  end

  it "mints a method the running app owns and the parser never saw" do
    out = described_class.build(reflection: reflection(m("Order", "merchant")),
                                forwarding: nil, table: table_with)
    expect(out.map(&:fq)).to eq(["Order#merchant"])
    expect(out.first.rel_file).to eq("app/order.rb")
    expect(out.first.line).to eq(3)
  end

  it "NEVER displaces a parsed `def` — a real definition owns its fq" do
    out = described_class.build(
      reflection: reflection(m("Order", "merchant")),
      forwarding: nil, table: table_with(methods: ["Order#merchant"])
    )
    expect(out).to be_empty
  end

  it "declines a method whose OWNING CLASS was never parsed — that is someone else's code" do
    out = described_class.build(reflection: reflection(m("Vendor::Thing", "id")),
                                forwarding: nil, table: table_with(classes: %w[Order]))
    expect(out).to be_empty
  end

  it "declines a gem-defined method: `app_site` false is not application source" do
    out = described_class.build(reflection: reflection(m("Order", "association", app_site: false)),
                                forwarding: nil, table: table_with)
    expect(out).to be_empty
  end

  it "declines a manifest with no app_site flag at all rather than claiming the whole app" do
    entry = m("Order", "merchant")
    entry.delete("app_site")
    expect(described_class.build(reflection: reflection(entry), forwarding: nil, table: table_with))
      .to be_empty
  end

  it "declines when there is no owner to anchor the node on" do
    entry = m("Order", "merchant", owner: nil)
    expect(described_class.build(reflection: reflection(entry), forwarding: nil, table: table_with))
      .to be_empty
  end

  it "returns nothing at all when reflection never ran" do
    expect(described_class.build(reflection: nil, forwarding: nil, table: table_with)).to eq([])
  end

  describe "forwarding targets" do
    it "points a forwarder at a PARSED method on its owner" do
      methods = [m("Order", "merchant")]
      out = described_class.build(
        reflection: reflection(*methods),
        forwarding: forwarding(methods, delegations: { "Order" => { "merchant" => "purchase" } }),
        table: table_with(methods: ["Order#purchase"])
      )
      expect(out.first.forwards_to).to eq("Order#purchase")
    end

    # `delegate :merchant, to: :program` sitting next to `delegate :program,
    # to: :earn` — one generated method forwarding to another. Checking targets
    # against the static table alone drops exactly the chained case this exists
    # to recover, so the second pass resolves against static UNION minted.
    it "points a forwarder at ANOTHER MINTED method — the chained-delegate case" do
      methods = [m("Order", "merchant"), m("Order", "program")]
      out = described_class.build(
        reflection: reflection(*methods),
        forwarding: forwarding(methods, delegations: {
                                 "Order" => { "merchant" => "program", "program" => "earn" }
                               }),
        table: table_with(methods: ["Order#earn"])
      )
      by_fq = out.to_h { |x| [x.fq, x.forwards_to] }
      expect(by_fq).to eq("Order#merchant" => "Order#program", "Order#program" => "Order#earn")
    end

    it "leaves the target NIL when it resolves to nothing — an edge to nowhere is worse than none" do
      methods = [m("Order", "merchant")]
      out = described_class.build(
        reflection: reflection(*methods),
        forwarding: forwarding(methods, delegations: { "Order" => { "merchant" => "context" } }),
        table: table_with
      )
      # `context` is supplied by the Interactor gem: not parsed, not minted, so
      # the chain honestly stops here rather than naming a target we do not have.
      expect(out.first.forwards_to).to be_nil
    end

    it "leaves the target nil when no forwarding fact exists (an attr_accessor has none)" do
      out = described_class.build(reflection: reflection(m("Order", "total")),
                                  forwarding: forwarding([]), table: table_with)
      expect(out.first.forwards_to).to be_nil
    end
  end
end
