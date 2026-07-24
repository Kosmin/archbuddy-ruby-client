# frozen_string_literal: true

require_relative "../../script/backtest/whitelist_reader"
require_relative "../../script/backtest/corpus"

# v0.15 P3-T3: the column-whitelist CSV reader — the A6 privacy rail.
RSpec.describe Backtest::WhitelistReader do
  CORPUS_FIXTURE = File.expand_path("../fixtures/backtest_corpus", __dir__)

  let(:prs_path) { File.join(CORPUS_FIXTURE, "data/derived/prs.csv") }
  let(:reader) { described_class.new(prs_path, allow: Backtest::Corpus::ALLOWLISTS["prs.csv"]) }

  it "never materializes a non-allowed cell into a row (TRIPWIRE proof)" do
    reader.rows.each do |row|
      expect(row.to_h.values.join).not_to include("TRIPWIRE_NEVER_READ")
      expect(row.to_h.keys).not_to include("author_login")
      expect(row.to_h.keys).not_to include("title")
    end
  end

  it "raises KeyError for a column outside the allowlist" do
    expect { reader.rows.first["author_login"] }.to raise_error(KeyError)
    expect { reader.rows.first["title"] }.to raise_error(KeyError)
  end

  it "reads the allowed columns faithfully (incl. quoted commas in dropped cells)" do
    row = reader.rows.first
    expect(row["repo"]).to eq("thanx/alpha")
    expect(row["pr_number"]).to eq("101")
    expect(row["base_sha"]).to eq("a" * 40)
    expect(row["arm"]).to eq("edit")
    expect(row["merged_at"]).to eq("2026-01-05T10:00:00Z")
    expect(reader.rows.size).to eq(3)
  end

  it "rejects allowlists containing author-shaped columns (defense in depth)" do
    %w[author_login login user_id actor email].each do |banned|
      expect { described_class.new(prs_path, allow: ["repo", banned]) }
        .to raise_error(ArgumentError, /banned author-shaped column/)
    end
  end

  it "keeps every corpus allowlist free of author-shaped columns" do
    Backtest::Corpus::ALLOWLISTS.each_value do |allow|
      expect(allow.grep(described_class::BANNED_COLUMNS)).to eq([])
    end
  end
end
