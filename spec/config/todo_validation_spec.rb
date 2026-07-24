# frozen_string_literal: true

require "tmpdir"
require "archbuddy/config"
require "archbuddy/config/todo"

# v0.15 P1-T3: the strict todo loader — R45 reject template, retired names,
# metric registry, shape confusion, stale headers.
RSpec.describe "Archbuddy::Config::Todo validation" do
  def errors_for(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".archbuddy_todo.yml")
      File.write(path, yaml)
      Archbuddy::Config::Todo.load(path)
      return []
    end
  rescue Archbuddy::Config::ValidationError => e
    e.message.split("\n")
  end

  def doc(rules_yaml, rule_count: 1, node_count: 1)
    <<~YAML
      version: 1
      tool: "archbuddy 0.12.0"
      rule_count: #{rule_count}
      node_count: #{node_count}
      rules:
      #{rules_yaml.gsub(/^/, '  ')}
    YAML
  end

  describe "never-grandfathered rules (R45 template)" do
    it "rejects ReviewSurface with the exact template" do
      errors = errors_for(doc(<<~YAML))
        ReviewSurface:
          - node: "a.rb: A#x"
            values: { escapes: 1 }
      YAML
      expect(errors).to include(
        "'ReviewSurface' is never grandfathered (L5) — grandfatherable: " \
        "ExponentialNode, FirewallBreaches, UseCaseComplexity, UseCaseDividend"
      )
    end

    %w[ComplexityRatchet MultiplicativeGrowth].each do |name|
      it "rejects #{name}" do
        errors = errors_for(doc("#{name}:\n  - node: \"a.rb: A#x\"\n    value: 1"))
        expect(errors.join).to include("'#{name}' is never grandfathered (L5)")
      end
    end
  end

  it "retired names get the RETIRED_RULES error naming the successor" do
    errors = errors_for(doc(<<~YAML))
      NoNewEscapes:
        - node: "a.rb: A#x"
          value: 1
    YAML
    expect(errors).to include(
      "unknown rule 'NoNewEscapes' at todo rules — retired: absorbed into FirewallBreaches " \
      "(its diff mode); see docs/CONFIGURATION.md#retired-rules"
    )
  end

  it "unknown rules get did-you-mean over the 4 GRANDFATHERABLE" do
    errors = errors_for(doc(<<~YAML))
      UseCaseComplexit:
        - node: "a.rb: A#x"
          values: { reach: 1 }
    YAML
    expect(errors).to include("unknown rule 'UseCaseComplexit' at todo rules — did you mean 'UseCaseComplexity'?")
  end

  describe "values-map validation" do
    it "values: {branching: 13.0} yields TWO errors (unknown metric + non-integer)" do
      errors = errors_for(doc(<<~YAML))
        UseCaseComplexity:
          - node: "a.rb: A#x"
            values: { branching: 13.0 }
      YAML
      expect(errors).to include(
        "unknown metric 'branching' at UseCaseComplexity entry — known: " \
        "branching_millilog2, depth, files, mass, max_cone_node_millilog2, reach"
      )
      expect(errors.join).to include("metric 'branching' must be a raw integer")
      expect(errors.size).to be >= 2
    end

    it "rejects an empty values map" do
      errors = errors_for(doc(<<~YAML))
        UseCaseDividend:
          - node: "a.rb: A#x"
            values: {}
      YAML
      expect(errors.join).to include("empty values map at UseCaseDividend entry")
    end
  end

  describe "entry-shape confusion (both directions)" do
    it "node-kind rule with values:" do
      errors = errors_for(doc(<<~YAML))
        ExponentialNode:
          - node: "a.rb: A#x"
            values: { escapes: 1 }
      YAML
      expect(errors).to include("'ExponentialNode' entries use value: (kind node)")
    end

    it "use-case rule with value:" do
      errors = errors_for(doc(<<~YAML))
        UseCaseDividend:
          - node: "a.rb: A#x"
            value: 32
      YAML
      expect(errors).to include("'UseCaseDividend' entries use values: (kind use_case)")
    end
  end

  it "rejects non-integer node-kind values" do
    errors = errors_for(doc(<<~YAML))
      ExponentialNode:
        - node: "a.rb: A#x"
          value: 81.5
    YAML
    expect(errors.join).to include("ExponentialNode entry value must be a raw integer")
  end

  it "rejects malformed node strings (no ': ' separator)" do
    errors = errors_for(doc(<<~YAML))
      ExponentialNode:
        - node: "not-a-node-string"
          value: 81
    YAML
    expect(errors.join).to include("ExponentialNode entry node must be a \"<file>: <symbol>\" string")
  end

  it "rejects stale header counts (hand-edit guard, G7)" do
    errors = errors_for(doc(<<~YAML, rule_count: 1, node_count: 2))
      ExponentialNode:
        - node: "a.rb: A#x"
          value: 81
    YAML
    expect(errors).to include("todo header counts stale — regenerate")
  end

  it "rejects unknown entry keys and unknown top-level keys" do
    errors = errors_for(<<~YAML)
      version: 1
      bogus: 1
      rule_count: 1
      node_count: 1
      rules:
        ExponentialNode:
          - node: "a.rb: A#x"
            value: 81
            extra: 1
    YAML
    expect(errors.join).to include("unknown key 'bogus' at todo top level")
    expect(errors.join).to include("unknown key 'extra' at ExponentialNode entry")
  end
end
