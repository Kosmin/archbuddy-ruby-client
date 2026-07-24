# frozen_string_literal: true

require "archbuddy/config/path_matcher"

# v0.15 P1-T1: PathMatcher — target-relative path globs (A6) + the F12
# ep-symbol matcher (exact-string FIRST — the `[0]` character-class trap).
RSpec.describe Archbuddy::Config::PathMatcher do
  describe ".match? (paths, FNM_PATHNAME | FNM_EXTGLOB)" do
    it "matches the live-verified glob semantics" do
      expect(described_class.match?(["app/api/**/*"], "app/api/api/v1/redeem_templates.rb")).to be(true)
      expect(described_class.match?(["vendor/**/*"], "app/models/user.rb")).to be(false)
    end

    it "takes the exact-string fast path for glob-free patterns" do
      expect(described_class.match?(["app/models/user.rb"], "app/models/user.rb")).to be(true)
      expect(described_class.match?(["app/models/user.rb"], "app/models/other.rb")).to be(false)
    end

    it "degenerates: empty glob list and empty path match nothing" do
      expect(described_class.match?([], "app/models/user.rb")).to be(false)
      expect(described_class.match?(["**/*"], "")).to be(false)
      expect(described_class.match?(nil, "x.rb")).to be(false)
    end
  end

  describe ".match_symbol? (ep symbols, F12 exact-string first)" do
    SYMBOL = "Api::V1::RedeemTemplates#PATCH[0]"

    it "matches a [0]-bearing symbol via the exact-string branch" do
      expect(described_class.match_symbol?([SYMBOL], SYMBOL)).to be(true)
    end

    it "proves the trap: bare fnmatch NEVER self-matches the [0] symbol" do
      # `[0]` parses as a character class — this is WHY exact-string equality
      # must run first (F12; live-verified on ruby-3.4.2).
      expect(File.fnmatch?(SYMBOL, SYMBOL, File::FNM_EXTGLOB)).to be(false)
    end

    it "still honors real globs (no FNM_PATHNAME — symbols are not paths)" do
      expect(described_class.match_symbol?(["Api::V1::*"], "Api::V1::Promotions#PATCH[0]")).to be(true)
      expect(described_class.match_symbol?(["Api::V2::*"], "Api::V1::Promotions#PATCH[0]")).to be(false)
    end

    it "degenerates: empty list / empty symbol match nothing" do
      expect(described_class.match_symbol?([], SYMBOL)).to be(false)
      expect(described_class.match_symbol?([SYMBOL], "")).to be(false)
      expect(described_class.match_symbol?(nil, SYMBOL)).to be(false)
    end
  end
end
