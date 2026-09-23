#!/usr/bin/env ruby
# frozen_string_literal: true

# Path-cost locator. Run from the client repo against any audited codebase:
#
#   ARCHITECTURE_AUDITOR_PATH=/path/to/engine \
#   bundle exec ruby script/cost_cascade.rb /path/to/audited/repo [--script-dirs lib/tasks,script]
#
# Requires a prior `archbuddy collect` (reads .archbuddy/{graph,id-map}.yml).
#
# WHAT IT ANSWERS
#   Before refactoring for complexity, answer three questions the -5..+5 score
#   cannot:
#
#   1. WHERE is the path cost?  Total cost is a logsumexp over entrypoints and is
#      routinely dominated by one route. If that route is a one-off migration
#      script, every refactor you make to production code will measure as zero.
#      The --script-dirs split exists to make that visible before you start.
#
#   2. Is it in BODIES or in TREES?  A body's own branch product and a call
#      tree's accumulated product are different problems with different fixes.
#      The cascade decomposes bodies only; whatever floor remains is tree-shaped.
#
#   3. Is there anything SHARED to split?  The hot-path sharing rate is printed
#      against the codebase-wide base rate. If they match, de-abstraction has no
#      surface where the cost is, whatever the reuse counts say globally.
#
# THE CASCADE MODEL
#   A body with b branches has d = log2(b) effective sequential decisions.
#   Splitting it into k units of <= D decisions turns a product into a sum:
#   b -> k * 2^(d/k). This is a MODEL of a refactor, not a measured one. Use the
#   ratios and the shape of the curve; do not quote the absolute counts.
#
# KNOWN BIASES (all directional, all understood)
#   - Branch counts inflate wherever control flow is chain-shaped (elsif, guard
#     chains) rather than nested, because those are multiplied as if independent.
#   - Unresolved call sites are missing edges. A body reachable only through
#     dynamic dispatch scores zero no matter how branchy it is, and the cascade
#     will under-report every such subsystem. Low reachability => every number
#     here is a LOWER BOUND of unknown tightness.

require "yaml"
require "set"

NEG = -Float::INFINITY

def lse(values)
  values = values.reject { |v| v == NEG }
  return NEG if values.empty?

  mx = values.max
  mx + Math.log(values.sum { |v| Math.exp(v - mx) })
end

def human(logv)
  v = Math.exp(logv)
  v < 1e7 ? v.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse : format("%.3e", v)
end

# b -> k * 2^(d/k), the sum-instead-of-product a decomposition buys.
def decompose(branches, max_decisions)
  d = Math.log2(branches)
  return branches if d <= max_decisions

  k = (d / max_decisions).ceil
  (k * (2**(d / k))).round
end

class CostGraph
  IN_TREE = %w[function endpoint].freeze

  attr_reader :entrypoints, :branches, :succ, :pred, :functions

  def initialize(root)
    dir = File.join(root, ".archbuddy")
    abort "no .archbuddy in #{root} — run `archbuddy collect` first" unless Dir.exist?(dir)

    graph  = YAML.unsafe_load_file(File.join(dir, "graph.yml"))
    @idmap = YAML.unsafe_load_file(File.join(dir, "id-map.yml"))["ids"] || {}
    @by_id = (graph["nodes"] || []).to_h { |n| [n["id"], n] }
    @entrypoints = (graph["entrypoints"] || []).map { |e| e.is_a?(Hash) ? e["id"] : e }.compact
    @branches = @by_id.transform_values { |n| [(n["branches"] || 1).to_i, 1].max }

    @succ = Hash.new { |h, k| h[k] = [] }
    @pred = Hash.new { |h, k| h[k] = [] }
    (graph["edges"] || []).each do |e|
      next if e["from"] == e["to"]

      @succ[e["from"]] << e["to"]
      @pred[e["to"]]   << e["from"]
    end
    @functions = @by_id.keys.select { |i| in_tree?(i) }
  end

  def in_tree?(id) = IN_TREE.include?(@by_id.dig(id, "kind"))
  def symbol(id)   = @idmap.dig(id, "symbol") || id
  def file(id)     = @idmap.dig(id, "file").to_s

  # mass(n) = log(branches n) + logsumexp(mass of children); cycles contribute nothing.
  def masses(branch_table = @branches)
    memo = {}
    visiting = {}
    rec = lambda do |id|
      return memo[id] if memo.key?(id)
      return NEG if visiting[id]

      visiting[id] = true
      kids = @succ[id]
      sub = kids.empty? ? 0.0 : lse(kids.map { |k| rec.call(k) })
      visiting.delete(id)
      memo[id] = Math.log(branch_table[id] || 1) + (sub == NEG ? 0.0 : sub)
    end
    rec
  end

  def total(branch_table = @branches)
    m = masses(branch_table)
    lse(@entrypoints.map { |e| m.call(e) })
  end

  # Greedy heaviest-child walk — the route the logsumexp is actually reporting.
  def hot_path(entry, mass_fn, limit = 8)
    chain = []
    cur = entry
    limit.times do
      kids = @succ[cur].select { |c| in_tree?(c) }.map { |c| [c, mass_fn.call(c)] }.reject { |_, v| v == NEG }
      break if kids.empty?

      cur = kids.max_by { |_, v| v }.first
      chain << cur
    end
    chain
  end
end

root = ARGV.first or abort "usage: cost_cascade.rb /path/to/audited/repo [--script-dirs a,b] [--max-decisions N]"
root = File.expand_path(root)
script_dirs = if (i = ARGV.index("--script-dirs"))
                ARGV[i + 1].split(",")
              else
                %w[lib/tasks script bin]
              end
max_decisions = (ARGV[ARGV.index("--max-decisions") + 1].to_i if ARGV.include?("--max-decisions")) || 4

g = CostGraph.new(root)
mass = g.masses
base = g.total
scripty = ->(id) { script_dirs.any? { |d| g.file(id).start_with?(d) } }

ranked_eps = g.entrypoints.map { |e| [e, mass.call(e)] }.sort_by { |_, v| -v }
puts format("TOTAL PATH COST: %s (e^%.3f) over %d entrypoints", human(base), base, g.entrypoints.size)

# ---- 1. where is it? -------------------------------------------------------
sc, prod = ranked_eps.partition { |e, _| scripty.call(e) }
[["script dirs (#{script_dirs.join(', ')})", sc], ["production", prod]].each do |label, set|
  next if set.empty?

  t = lse(set.map(&:last))
  puts format("  %-34s %3d entrypoints  %14s  %5.1f%%", label, set.size, human(t), 100 * Math.exp(t - base))
end
puts "\nCONCENTRATION"
sorted = ranked_eps.map(&:last)
[1, 5, 20].each do |n|
  puts format("  top %-3d entrypoints = %5.1f%% of total cost", n, 100 * Math.exp(lse(sorted.first(n)) - base))
end
puts "\nTOP ENTRYPOINTS"
ranked_eps.first(8).each_with_index do |(id, v), i|
  puts format("  %d. %-52s %13s %5.1f%% %s", i + 1, g.symbol(id).to_s[0, 52], human(v),
              100 * Math.exp(v - base), scripty.call(id) ? "[script]" : "")
end

# ---- 2. bodies or trees? ---------------------------------------------------
carriers = g.functions.select { |i| g.branches[i] > 2**max_decisions }.sort_by { |i| -g.branches[i] }
puts format("\nBODY COST CARRIERS: %d of %d functions (%.1f%%) exceed 2^%d branches",
            carriers.size, g.functions.size, 100.0 * carriers.size / [g.functions.size, 1].max, max_decisions)
puts format("\nCASCADE — decompose the top-k branchiest bodies into units of <= %d decisions", max_decisions)
puts format("  %-6s %14s %9s  %s", "k", "paths", "vs base", "last one touched")
steps = [0, 1, 2, 3, 5, 10, 20, 50, carriers.size].uniq.select { |k| k <= carriers.size }
floor_table = nil
steps.each do |k|
  table = g.branches.dup
  carriers.first(k).each { |i| table[i] = decompose(g.branches[i], max_decisions) }
  t = g.total(table)
  floor_table = table if k == carriers.size
  last = k.zero? ? "—" : format("%s (2^%.0f)", g.symbol(carriers[k - 1]).to_s[0, 38], Math.log2(g.branches[carriers[k - 1]]))
  puts format("  %-6d %14s %8.1fx  %s", k, human(t), Math.exp(base - t), last)
end

if floor_table
  floor = g.total(floor_table)
  fmass = g.masses(floor_table)
  top_id, top_v = g.entrypoints.map { |e| [e, fmass.call(e)] }.max_by { |_, v| v }
  puts format("\nFLOOR after decomposing every body: %s (%.1fx). Top residual is %.1f%% of it:",
              human(floor), Math.exp(base - floor), 100 * Math.exp(top_v - floor))
  puts format("  %-52s own branches=%d", g.symbol(top_id).to_s[0, 52], g.branches[top_id])
  puts "  -> residual cost is TREE-shaped (accumulated down a chain), not body-shaped." \
       if g.branches[top_id] <= 2**max_decisions
end

# ---- 3. anything shared to split? ------------------------------------------
hot = ranked_eps.first(20).flat_map { |e, _| g.hot_path(e, mass) }
shared_hot = hot.count { |n| g.pred[n].size > 1 }
shared_all = g.functions.count { |i| g.pred[i].size > 1 }
puts "\nIS THERE ANYTHING TO FLATTEN ON THE EXPENSIVE ROUTES?"
puts format("  hot-path nodes (top 20 entrypoints): %4d  shared %4d = %.1f%%", hot.size, shared_hot,
            100.0 * shared_hot / [hot.size, 1].max)
puts format("  codebase-wide base rate:             %4d  shared %4d = %.1f%%", g.functions.size, shared_all,
            100.0 * shared_all / [g.functions.size, 1].max)
enrichment = (100.0 * shared_hot / [hot.size, 1].max) / [(100.0 * shared_all / [g.functions.size, 1].max), 0.01].max
puts format("  enrichment: %.2fx  -> %s", enrichment,
            enrichment < 1.3 ? "hot routes are NOT reuse-enriched; splitting shared nodes has no surface here" : "hot routes ARE reuse-enriched; shared-node splitting is worth probing")
