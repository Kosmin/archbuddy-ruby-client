#!/usr/bin/env ruby
# frozen_string_literal: true

# CCO extraction-dividend probe (repo-only, unpackaged). Run from the client
# repo against any audited codebase:
#
#   ARCHITECTURE_AUDITOR_PATH=/path/to/engine \
#   bundle exec ruby script/cco_dividend.rb /path/to/audited/repo [--top N]
#
# Requires a prior `archbuddy collect` + `analyze` in the target (it reads
# .archbuddy/findings.yml for the `cco` locality flags and .archbuddy/id-map.yml
# to resolve nodes back to source).
#
# WHAT IT ANSWERS
#   Given a C+O hybrid (a body that BOTH dispatches onward and crosses a
#   boundary itself), how much of its branch factor is actually EXTRACTABLE by
#   splitting it into CCO layers — as opposed to already being flat, where a
#   split would merely relocate the branching?
#
#   own_after = b_total / PRODUCT(extractable factors)
#   dividend  = b_total / own_after
#
#   Extractable = every decision nested inside another decision's arm, plus any
#   top-level multi-arm construct (>= 3 arms — that is a control layer). An
#   `elsif` continuation is at the SAME level as its head: an alternative, not
#   a nest.
#
# WHAT IT IS: A CANDIDATE FINDER, NOT A YIELD PREDICTOR.
#   Measured over 16 real splits (two batches, the second committed to before
#   being measured), the dividend's rank correlation with the actual CONTEXT
#   reduction a split delivers is +0.40 combined and 0.00 out-of-sample. Its top
#   pick on one corpus (32x) delivered a mid-pack context win; a body it scored
#   1.0x ("skip") delivered one of the best. So: use it to narrow thousands of
#   hybrids to a short list worth reading. Never quote a predicted yield from it.
#
# CAVEATS (do not publish magnitudes without reading these)
#   - Predicts PER-BODY factor reduction only — validated exactly on 3 splits.
#     It does NOT predict the context win (see above), and tree path count
#     dissociates from both. Score bodies, not trees.
#   - `b` comes from BranchCounter, which multiplies `elsif` and guard chains
#     where they are semantically alternatives. Ranking is usable; magnitudes
#     are inflated wherever the branching is chain-shaped rather than nested.
#   - Says nothing about whether a split is semantically coherent. Some long
#     hybrids are templates (one big heredoc), not layered logic; those yield
#     almost nothing and the score cannot tell them apart.

require "prism"
require "yaml"
require "architecture_auditor"
require_relative "../lib/archbuddy/collect/adapters/ruby/definition_pass"

BC = Archbuddy::Collect::Adapters::Ruby::BranchCounter

DECISION = lambda do |n|
  n.is_a?(Prism::IfNode) || n.is_a?(Prism::UnlessNode) ||
    n.is_a?(Prism::CaseNode) || n.is_a?(Prism::WhileNode) || n.is_a?(Prism::UntilNode)
end

def factor(node)
  node.is_a?(Prism::CaseNode) ? node.conditions.size + (node.else_clause ? 1 : 0) : 2
end

def subsequent_of(node)
  node.respond_to?(:subsequent) ? node.subsequent : node.consequent
end

# Every decision in the body, tagged with its DECISION-NESTING depth.
def decisions(node, depth = 0, acc = [], elsif_continuation = false)
  return acc if node.nil?

  unless DECISION.call(node)
    node.child_nodes.compact.each { |k| decisions(k, depth, acc) }
    return acc
  end

  acc << { depth: depth, factor: factor(node) } unless elsif_continuation
  if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
    decisions(node.statements, depth + 1, acc)
    nxt = subsequent_of(node)
    nxt.is_a?(Prism::IfNode) ? decisions(nxt, depth, acc, true) : decisions(nxt, depth + 1, acc)
  else
    node.child_nodes.compact.each { |k| decisions(k, depth + 1, acc) }
  end
  acc
end

def dividend(body)
  total = BC.count(body).branches
  found = decisions(body)
  extractable = found.select { |d| d[:depth] >= 1 || (d[:depth].zero? && d[:factor] >= 3) }
  product = extractable.map { |d| d[:factor] }.inject(1, :*)
  own_after = [total / [product, 1].max, 1].max
  { b: total, own_after: own_after, dividend: total.fdiv(own_after),
    layers: extractable.size, levels: found.group_by { |d| d[:depth] }.transform_values { |v| v.map { |x| x[:factor] } } }
end

root = ARGV.first or abort "usage: cco_dividend.rb /path/to/audited/repo [--top N]"
root = File.expand_path(root)
top  = (ARGV[ARGV.index("--top") + 1].to_i if ARGV.include?("--top")) || 15
dir  = File.join(root, ".archbuddy")
abort "no .archbuddy in #{root} — run `archbuddy collect` first" unless Dir.exist?(dir)

findings = YAML.unsafe_load_file(File.join(dir, "findings.yml"))
idmap    = YAML.unsafe_load_file(File.join(dir, "id-map.yml"))["ids"]

# C+O is the depth-free, semantically real hybrid: dispatches onward AND exits itself.
hybrids = {}
(findings["locality"] || {}).each do |id, lo|
  cco = lo["cco"]
  next if cco.nil? || !(cco["control"] && cco["operation"])

  entry = idmap[id]
  next unless entry && entry["file"] && entry["line"]

  hybrids[[entry["file"], entry["line"]]] = entry["symbol"]
end

rows = []
joined = 0
Dir.glob(File.join(root, "{app,lib,src}/**/*.rb")).each do |path|
  parsed = begin
    Prism.parse_file(path)
  rescue StandardError
    next
  end
  next unless parsed.success?

  rel = path.sub("#{root}/", "")
  walk = lambda do |n|
    if n.is_a?(Prism::DefNode) && (sym = hybrids[[rel, n.location.start_line]])
      joined += 1
      rows << dividend(n.body).merge(sym: sym, file: rel, line: n.location.start_line,
                                     lines: n.location.end_line - n.location.start_line + 1)
    end
    n.child_nodes.compact.each { |k| walk.call(k) }
  end
  walk.call(parsed.value)
end

actionable = rows.select { |r| r[:dividend] > 1.0 }
puts "C+O hybrids: #{hybrids.size}  joined to a parsed def: #{joined} (#{(100.0 * joined / [hybrids.size, 1].max).round(1)}%)"
puts "  with an extraction dividend > 1: #{actionable.size} (#{(100.0 * actionable.size / [rows.size, 1].max).round(1)}%)"
if actionable.empty?
  puts "  nothing actionable — every hybrid's branching is already flat."
  exit 0
end

sorted = actionable.map { |r| r[:dividend] }.sort
puts "\nDIVIDEND DISTRIBUTION (predicted per-body factor reduction)"
[0.5, 0.75, 0.9].each { |q| puts format("  p%-3d  %5.1fx", q * 100, sorted[(sorted.size * q).to_i]) }
puts format("  max   %5.1fx   |  >=3x: %d  >=6x: %d  >=12x: %d", sorted.max,
            actionable.count { |r| r[:dividend] >= 3 },
            actionable.count { |r| r[:dividend] >= 6 },
            actionable.count { |r| r[:dividend] >= 12 })
puts format("\nAGGREGATE over %d actionable hybrids: own-body combinations %d -> %d (%.1fx), +%d layer methods implied",
            actionable.size, actionable.sum { |r| r[:b] }, actionable.sum { |r| r[:own_after] },
            actionable.sum { |r| r[:b] }.fdiv(actionable.sum { |r| r[:own_after] }),
            actionable.sum { |r| r[:layers] })

puts "\nTOP #{top} BY PREDICTED DIVIDEND"
puts format("%-46s %6s %6s %7s %7s %6s", "method", "b", "after", "div", "layers", "lines")
actionable.sort_by { |r| [-r[:dividend], -r[:b]] }.first(top).each do |r|
  puts format("%-46s %6d %6d %6.1fx %7d %6d", r[:sym].to_s[0, 46], r[:b], r[:own_after], r[:dividend], r[:layers], r[:lines])
  puts "      #{r[:file]}:#{r[:line]}   levels #{r[:levels].inspect}"
end
