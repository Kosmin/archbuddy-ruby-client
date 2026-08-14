# frozen_string_literal: true

require "spec_helper"
require "archbuddy/collect/engine_preflight"

# configurator W2 (C1). The gemspec declares `architecture_auditor >= 0.12`,
# and NEITHER of the two wiring modes a developer actually uses honours it: a
# `git:` Gemfile source and `ARCHITECTURE_AUDITOR_PATH` both load whatever
# checkout they are pointed at. This is the check that actually runs.
RSpec.describe Archbuddy::Collect::EnginePreflight do
  it "passes against the engine this suite is wired to" do
    expect(described_class.satisfied?).to be(true)
    expect(described_class.check!).to be(true)
  end

  # THE MUTATION THAT MATTERS: the failure must name the VERSION. A NameError
  # from inside the resolver, or a SchemaError from the profile loader, would
  # both be true and both be useless — they read as collector bugs.
  it "refuses an engine below the floor with a version message, not a NameError" do
    stub_const("ArchitectureAuditor::VERSION", "0.11.0")

    expect(described_class.satisfied?).to be(false)
    expect(described_class.message).to eq("architecture_auditor >= 0.12 required, found 0.11.0")
    expect { described_class.check! }
      .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      .and output(/architecture_auditor >= 0\.12 required, found 0\.11\.0/).to_stderr
  end

  # Two independent facts, both required. A checkout can carry a bumped VERSION
  # without the constant the collector actually calls.
  it "refuses an engine whose version is new enough but that serves no profiles" do
    contract = ArchitectureAuditor::Contract
    allow(contract).to receive(:const_defined?).with(:Profiles).and_return(false)

    expect(described_class.satisfied?).to be(false)
  end

  it "refuses an unparseable version rather than guessing" do
    stub_const("ArchitectureAuditor::VERSION", "not-a-version")

    expect(described_class.satisfied?).to be(false)
  end
end
