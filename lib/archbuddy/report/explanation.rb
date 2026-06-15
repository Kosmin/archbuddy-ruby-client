# frozen_string_literal: true

module Archbuddy
  module Report
    # R-4 (D19): the explanation table. Maps ALL 7 finding types (D38) to a
    # plain-English account of WHY the item is clutter, framed along the two axes
    # the tool cares about:
    #
    #   - forward discoverability  — "from here, can I find what this reaches?"
    #   - reverse traceability     — "who reaches here? is it safe to change?"
    #
    # This teaches the user how to read each bottleneck, not just that it scored
    # highly. The text is parameterized on the relevant metric value when one is
    # available (e.g. fan_in count, path length) so explanations are concrete.
    module Explanation
      # The 7 contract finding types (D38). Node-type carry a count metric;
      # path-type carry a chain length.
      TABLE = {
        "high_fan_in" => {
          title: "High fan-in",
          axis:  "reverse traceability",
          summary: "Called from many places — risky to change.",
          detail: "Lots of callers depend on this symbol. A change here ripples " \
                  "outward to every caller, so reverse traceability is poor: it is " \
                  "hard to know everyone you might break."
        },
        "high_fan_out" => {
          title: "High fan-out",
          axis:  "forward discoverability",
          summary: "Calls many other things — hard to follow.",
          detail: "This symbol reaches into many collaborators. Forward " \
                  "discoverability suffers: understanding what it actually does " \
                  "means chasing a wide spray of downstream calls."
        },
        "high_centrality" => {
          title: "High centrality",
          axis:  "both directions",
          summary: "A chokepoint on many call paths — fragile hub.",
          detail: "This symbol sits on a large share of the shortest paths through " \
                  "the system. It is a hub: both forward discoverability and reverse " \
                  "traceability route through it, so it is a single point of fragility."
        },
        "orphan" => {
          title: "Orphan",
          axis:  "reverse traceability",
          summary: "No callers reach it — unreachable from entrypoints.",
          detail: "Nothing reaches this symbol from a known entrypoint. Reverse " \
                  "traceability is broken at the top: it may be unused, mis-wired, " \
                  "or only reachable through metaprogramming the static pass cannot see."
        },
        "dead" => {
          title: "Dead",
          axis:  "forward discoverability",
          summary: "Reaches nothing and nothing reaches it — likely removable.",
          detail: "This symbol is isolated: no inbound and no outbound edges. It is " \
                  "clutter that adds surface area with no behavior — a strong " \
                  "candidate for deletion once confirmed not dynamically invoked."
        },
        "long_path" => {
          title: "Long path",
          axis:  "forward discoverability",
          summary: "A deep call chain — poor forward discoverability.",
          detail: "Following intent from the entrypoint to the end of this chain " \
                  "crosses many hops. Forward discoverability is poor: the behavior " \
                  "is smeared across a long sequence of indirections."
        },
        "cycle" => {
          title: "Cycle",
          axis:  "both directions",
          summary: "A call cycle — tangles forward and reverse reasoning.",
          detail: "These symbols call back into one another. A cycle defeats both " \
                  "forward discoverability and reverse traceability: there is no " \
                  "clean top or bottom, so reasoning about cause and effect loops."
        }
      }.freeze

      module_function

      # @return [Hash,nil] the explanation entry for a finding type (nil if unknown).
      def for(type)
        TABLE[type.to_s]
      end

      # A one-line, value-aware explanation for a de-anonymized finding.
      # @param finding [Model::Finding]
      def describe(finding)
        entry = TABLE[finding.type.to_s]
        return "#{finding.type}: (no explanation registered)" if entry.nil?

        suffix = path_suffix(finding)
        "#{entry[:title]} — #{entry[:summary]}#{suffix} [#{entry[:axis]}]"
      end

      def path_suffix(finding)
        return "" unless finding.respond_to?(:path?) && finding.path?

        hops = finding.path_refs.length
        " (#{hops}-node chain)"
      end
    end
  end
end
