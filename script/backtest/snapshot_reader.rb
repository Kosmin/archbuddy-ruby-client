# frozen_string_literal: true

require_relative "../../lib/archbuddy/review"

module Backtest
  # Snapshot access (A6/L12 privacy rail): for `snapshots/<sha>/` we open
  # EXACTLY (a) `archbuddy-findings.json` and (b) the fragment files its
  # `sources` map points at — NEVER `id-map.json`, `id-map.yml`,
  # `findings.json`, `findings.yml`, or `provenance.json` (the SECRETs that
  # sit beside study-snapshot aggregates).
  #
  # Delegates to `Review::FragmentWalk.read` (R5 — the ONE reader): its walk
  # is pointer-driven only and already performs the dotted↔un-dotted
  # fragment-root prefix-swap the exported study layout needs. The spy-ban
  # spec asserts the read set against the F2-corrected pattern
  # /id-map|(?<!archbuddy-)findings\.(json|yml)|provenance/.
  module SnapshotReader
    module_function

    # @param snapshot_dir [String] `<corpus>/snapshots/<sha>`
    # @return [Archbuddy::Review::Vintage]
    def read(snapshot_dir)
      Archbuddy::Review::FragmentWalk.read(snapshot_dir)
    end
  end
end
