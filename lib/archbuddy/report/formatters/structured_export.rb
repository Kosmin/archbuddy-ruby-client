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
          doc = {
            "generator"     => context.generator,
            "bottlenecks"   => context.ranked.map { |b| node_hash(b, metric_keys) },
            "class_rollups" => context.class_rollups.map { |r| rollup_hash(r) }
          }
          # findings 1.1: include the de-anonymized project dimension scores so
          # machine consumers get them too. Omitted entirely for a 1.0 doc
          # (context.scores nil) — back-compat with existing consumers.
          doc["scores"] = scores_hash(context.scores) if context.scores && !context.scores.empty?
          doc
        end

        # De-anonymized project scores keyed by dimension. score/grade VERBATIM;
        # hotspots resolved to real {symbol, file:line} + their driving metrics.
        def scores_hash(scores)
          scores.each_with_object({}) do |dim, h|
            h[dim.key] = {
              "score"     => dim.score,
              "grade"     => dim.grade,
              "question"  => dim.question,
              "na_reason" => dim.na_reason,
              "hotspots"  => dim.hotspots.map { |hs| hotspot_hash(hs) }
            }.compact
          end
        end

        def hotspot_hash(hotspot)
          loc = hotspot.location
          {
            "symbol"   => loc.symbol,
            "file"     => loc.file,
            "line"     => loc.line,
            "resolved" => loc.resolved?,
            "metrics"  => hotspot.metrics
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
