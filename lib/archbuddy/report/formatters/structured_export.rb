# frozen_string_literal: true

module Archbuddy
  module Report
    module Formatters
      # Shared builder turning a RenderContext into a plain-data Hash that the
      # YAML and JSON formatters serialize. The de-anonymized export is
      # SECRET/local-only (it carries real file/symbol names — D16/D21).
      #
      # Values are echoed VERBATIM from the joined findings (D17) — no recompute.
      module StructuredExport
        module_function

        def build(context, metric_keys)
          {
            "generator"     => context.generator,
            "bottlenecks"   => context.ranked.map { |b| node_hash(b, metric_keys) },
            "class_rollups" => context.class_rollups.map { |r| rollup_hash(r) }
          }
        end

        def node_hash(bottleneck, metric_keys)
          loc = bottleneck.location
          {
            "id"            => bottleneck.id,
            "symbol"        => loc.symbol,
            "file"          => loc.file,
            "line"          => loc.line,
            "kind"          => bottleneck.kind,
            "class_id"      => bottleneck.class_id,
            "resolved"      => loc.resolved?,
            "clutter_score" => bottleneck.clutter_score,
            "metrics"       => metric_keys.each_with_object({}) { |k, h| h[k] = bottleneck.metrics[k] },
            "findings"      => bottleneck.findings.map { |f| finding_hash(f) }
          }
        end

        def rollup_hash(rollup)
          loc = rollup.location
          {
            "class_id"      => rollup.id,
            "symbol"        => loc.symbol,
            "file"          => loc.file,
            "line"          => loc.line,
            "resolved"      => loc.resolved?,
            "clutter_score" => rollup.clutter_score,
            "member_count"  => rollup.metrics["member_count"]
          }
        end

        def finding_hash(finding)
          {
            "type"     => finding.type,
            "severity" => finding.severity,
            "node"     => finding.node&.symbol,
            "chain"    => (finding.path? ? finding.path_refs.map(&:symbol) : nil)
          }.compact
        end
      end
    end
  end
end
