# frozen_string_literal: true

require "archbuddy/report"
require "architecture_auditor"
# The engine's top-level entrypoint deliberately loads only the Contract layer;
# the Processor (Analyze) is required on demand. Load it so we can read the
# engine's canonical METRIC_KEYS and assert the client half matches it.
require "architecture_auditor/analyze"

# The CLIENT HALF of the 4c cross-repo metric-kernel consistency test (D43/D39).
#
# The reporter's display metric set MUST equal the engine's canonical metric
# kernel. If the engine adds/removes/renames a metric and the client doesn't
# follow (or vice versa), this spec fails CI — forcing the two halves of the
# system to stay in lockstep on the exact metric set, in the exact order.
RSpec.describe "Metric-kernel consistency (client half — D43)" do
  it "exposes METRIC_KEYS_FOR_DISPLAY as a named constant (not an inline literal)" do
    expect(Archbuddy::Report.const_defined?(:METRIC_KEYS_FOR_DISPLAY)).to be(true)
    expect(Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY).to be_frozen
  end

  it "equals the engine's source-of-truth ArchitectureAuditor::Analyze::METRIC_KEYS" do
    client = Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY.map(&:to_sym)
    engine = ArchitectureAuditor::Analyze::METRIC_KEYS

    # Same set AND same order (the breakdown is displayed in this order).
    expect(client).to eq(engine)
  end
end
