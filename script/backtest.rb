#!/usr/bin/env ruby
# frozen_string_literal: true

# archbuddy backtest harness (repo-only, unpackaged). Run from the client
# repo:
#
#   ARCHBUDDY_STUDY_CORPUS=~/Projects/nexus-complexity-study \
#   [ARCHBUDDY_STUDY_REPOS="org/name=abs_path[:subdir],…"] \
#   bundle exec ruby script/backtest.rb --tier 0|1|2|3|all [--sample N]
#     [--pairs base-merge|merge-parent] [--out DIR] [--strict]
#
# Exits 0 (ran or skipped gracefully), 1 (≥1 gate false), 2 (corpus/tool
# error). The study corpus is READ-ONLY; heads cache under gitignored
# tmp/backtest/ (A6/L12).

require_relative "backtest/cli"

exit Backtest::CLI.run(ARGV)
