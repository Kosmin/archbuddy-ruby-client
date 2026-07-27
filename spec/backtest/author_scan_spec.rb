# frozen_string_literal: true

require_relative "../../script/backtest/author_scan"

# v0.15 P3-T8: the A6 author-scan — identifier classes only, zero-match
# required (no allowlist), degenerate-document guard.
RSpec.describe Backtest::AuthorScan do
  CLEAN_DOC = <<~MD
    # archbuddy backtest

    | metric | value |
    |---|---|
    | flag rate | 21/239 |

    The author-scan verifies no author identifiers appear (the prose word
    "author" is allowed).
  MD

  it "passes a clean document (prose 'author' allowed)" do
    expect(described_class.scan(CLEAN_DOC)).to eq([])
    expect(described_class.degenerate?(CLEAN_DOC)).to be(false)
  end

  it "rejects a seeded GitHub handle" do
    expect(described_class.scan("#{CLEAN_DOC}\nthanks @some-handle for the PR\n"))
      .to include("@some-handle")
  end

  it "rejects a seeded email address" do
    expect(described_class.scan("#{CLEAN_DOC}\ncontact person@example.com\n"))
      .to include("person@example.com")
  end

  it "flags empty and adoption-table-free documents as degenerate" do
    expect(described_class.degenerate?("")).to be(true)
    expect(described_class.degenerate?("# a doc without the pitch table\n")).to be(true)
  end
end
