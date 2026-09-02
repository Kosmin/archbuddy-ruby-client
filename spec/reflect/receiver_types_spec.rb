# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "archbuddy/reflect"

RSpec.describe ArchbuddyTraceProbe do
  # The probe is exercised for real rather than stubbed: the whole point is that
  # it observes an EXECUTION, so a test that does not execute anything would be
  # testing nothing. OpenStruct is used because it IS the shape that matters —
  # Interactor::Context inherits its dynamism from exactly this class.
  # THE CONSTRUCTION HOOK, which is the one that behaves the same on every
  # Ruby. Measured: a key set at construction and then read fires
  # method_missing on 2.7.5 but NOT on 3.4.2, because Ruby 3's OpenStruct
  # defines its members eagerly. `initialize` sees the whole hash on both.
  it "records types from the construction hash — identically on any Ruby" do
    require "ostruct"
    described_class::OBSERVED.clear
    tp = TracePoint.new(:return) { |t| described_class.record_initialize(t) }
    tp.enable(target: OpenStruct.instance_method(:initialize)) do
      OpenStruct.new(merchant: "acme", count: 7)
    end

    observed = described_class::OBSERVED
    expect(observed[["OpenStruct", "merchant"]]).to eq("String" => 1)
    expect(observed[["OpenStruct", "count"]]).to eq("Integer" => 1)
  end

  # THE LATE-ASSIGNMENT HOOK. This one fires on every Ruby, because a key the
  # object was not built with genuinely misses. Note WHICH call misses: the
  # assignment does, and it defines the member, so the following read does not.
  # That is why a setter observation has to count.
  it "records a key assigned after construction, which the hash never saw" do
    require "ostruct"
    described_class::OBSERVED.clear
    bag = OpenStruct.new
    tp = TracePoint.new(:return) { |t| described_class.record_missing(t) }
    tp.enable(target: OpenStruct.instance_method(:method_missing)) do
      bag.later = "assigned"
      bag.later
    end
    expect(described_class::OBSERVED.keys.map(&:last)).to include("later")
  end

  it "reads the missed name off the frame by its DECLARED parameter name" do
    # `method_missing(mid, *args)` in stdlib, but a gem may call it anything.
    # Reading `parameters.first` rather than assuming `mid` is what keeps this
    # working across implementations.
    require "ostruct"
    described_class::OBSERVED.clear
    bag = OpenStruct.new
    tp = TracePoint.new(:return) { |t| described_class.record_missing(t) }
    tp.enable(target: OpenStruct.instance_method(:method_missing)) { bag.zzz = 1 }
    # Recorded under `zzz`, not `zzz=`: a write tells us the key's type, and
    # filing it under the setter name would use a name no call site writes.
    expect(described_class::OBSERVED.keys.map(&:last)).to eq(["zzz"])
  end

  # REGRESSION. The objects being traced are the ones that intercept unknown
  # methods, and blank-slate proxies intercept `class` as well — so asking
  # `obj.class` returns whatever the proxy decides AND re-enters the hook we are
  # inside. Measured against a real app before this was fixed: 513 of 584
  # observations were filed under a receiver class literally named "class".
  it "reads the receiver's REAL class even when the object lies about it" do
    stub_const("LyingProxy", Class.new do
      def method_missing(name, *) = name == :class ? "class" : 42
      def respond_to_missing?(*) = true
    end)
    described_class::OBSERVED.clear
    obj = LyingProxy.new
    tp = TracePoint.new(:return) { |t| described_class.record_missing(t) }
    tp.enable(target: LyingProxy.instance_method(:method_missing)) { obj.anything }

    expect(described_class::OBSERVED.keys).to eq([["LyingProxy", "anything"]])
  end

  it "records nothing rather than a made-up name when the class is anonymous" do
    described_class::OBSERVED.clear
    anon = Class.new { def method_missing(*) = 1 }
    tp = TracePoint.new(:return) { |t| described_class.record_missing(t) }
    tp.enable(target: anon.instance_method(:method_missing)) { anon.new.whatever }
    expect(described_class::OBSERVED).to be_empty
  end

  # REGRESSION. A frame's path is recorded AS IT WAS WRITTEN, so a script run as
  # `ruby tmp/driver.rb` yields a RELATIVE path while a required file yields an
  # absolute one. A bare prefix test dropped every frame from the very file
  # being exercised — measured: 84 observations recorded and not one from it,
  # which reads as a working feature rather than a broken filter.
  it "accepts an app frame whose path is RELATIVE, as a script's frames are" do
    described_class.instance_variable_set(:@root, "/srv/app")
    expect(described_class.app_frame?("tmp/driver.rb")).to be(true)
    expect(described_class.app_frame?("/srv/app/app/models/order.rb")).to be(true)
    expect(described_class.relative("tmp/driver.rb")).to eq("tmp/driver.rb")
  end

  it "still rejects a bundled gem, which installs UNDER the project root" do
    described_class.instance_variable_set(:@root, "/srv/app")
    expect(described_class.app_frame?("/srv/app/.devbox/virtenv/ruby/gems/x/lib/y.rb")).to be(false)
    expect(described_class.app_frame?("/elsewhere/thing.rb")).to be(false)
  end

  it "selects ONLY bag sources from the manifest — delegators and unknowns are not black boxes" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".archbuddy"))
      File.write(File.join(dir, ".archbuddy", "reflection.json"), JSON.dump(
                   "dynamic_interfaces" => { "sources" => {
                     "OpenStruct"                    => { "kind" => "bag" },
                     "Draper::AutomaticDelegation"   => { "kind" => "delegator", "via" => "object" },
                     "ActiveModel::AttributeMethods" => { "kind" => "unknown" },
                     "Exception"                     => { "kind" => "native" }
                   } }
                 ))
      expect(described_class.bag_sources(dir)).to eq(["OpenStruct"])
    end
  end

  it "returns no sources rather than raising when reflection never ran" do
    Dir.mktmpdir { |dir| expect(described_class.bag_sources(dir)).to eq([]) }
  end
end

RSpec.describe Archbuddy::Reflect::ReceiverTypes do
  def build(rows, unattached: [])
    described_class.from_manifest("types" => rows, "unattached" => unattached)
  end

  it "reports a single observed type as the receiver's type" do
    t = build([{ "class" => "Interactor::Context", "name" => "merchant", "observed" => { "Merchant" => 12 } }])
    expect(t.type_of("Interactor::Context", "merchant")).to eq("Merchant")
  end

  it "REFUSES to pick a winner when two flows disagree" do
    # `context.source` really is a Purchase here and a Receipt there. The union
    # is the true answer; choosing the more frequent one would dress a
    # fabrication up as a measurement.
    t = build([{ "class" => "Interactor::Context", "name" => "source",
                 "observed" => { "Purchase" => 90, "Receipt" => 2 } }])
    expect(t.type_of("Interactor::Context", "source")).to be_nil
    expect(t.observation("Interactor::Context", "source")).to be_ambiguous
    expect(t.observation("Interactor::Context", "source").total).to eq(92)
  end

  it "does not let NilClass become a type" do
    # "it was nil once" says nothing about what the key holds.
    t = build([{ "class" => "C", "name" => "x", "observed" => { "NilClass" => 5 } }])
    expect(t.type_of("C", "x")).to be_nil
    expect(t).to be_empty
  end

  it "keeps the real type when nil was ALSO observed" do
    t = build([{ "class" => "C", "name" => "x", "observed" => { "NilClass" => 5, "Merchant" => 1 } }])
    expect(t.type_of("C", "x")).to eq("Merchant")
  end

  it "behaves as if it does not exist when no trace was ever run" do
    t = described_class.from_file("/nonexistent/receiver_types.json")
    expect(t).to be_empty
    expect(t.type_of("Anything", "at_all")).to be_nil
    expect(t.stats[:pairs]).to eq(0)
  end

  it "survives a corrupt trace file rather than failing the run that reads it" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "receiver_types.json")
      File.write(path, "{not json")
      expect(described_class.from_file(path)).to be_empty
    end
  end

  it "surfaces unattached bag sources, so a thin trace reads as a coverage problem" do
    t = build([], unattached: %w[Stripe::StripeObject])
    expect(t.unattached).to eq(%w[Stripe::StripeObject])
    expect(t.stats[:unattached]).to eq(1)
  end

  it "counts ambiguous and unambiguous separately — they mean different things" do
    t = build([{ "class" => "C", "name" => "a", "observed" => { "X" => 1 } },
               { "class" => "C", "name" => "b", "observed" => { "X" => 1, "Y" => 1 } }])
    expect(t.stats).to include(pairs: 2, unambiguous: 1, ambiguous: 1)
  end
end
