# frozen_string_literal: true

require "archbuddy/review"

# v0.15 P3-T2: L8's "advisory copy only, never gate inputs" frozen as a grep
# spec. Calibration values may be READ only by the presenter stack (the
# calibration module itself, formatters, the ReviewContext home, config
# validation, and the two CLI commands). lib/archbuddy/review.rb is allowed
# for its require lines ONLY ([S:F4]) — no value reads.
RSpec.describe "calibration isolation (L8 presenter-only)" do
  REPO_ROOT_ISOLATION = File.expand_path("../..", __dir__)

  # [S:F4] allowlist (R30: the ReviewContext home is review/formatter.rb).
  ALLOWED = [
    %r{\Alib/archbuddy/review/calibration},          # the module + lines.rb
    %r{\Alib/archbuddy/review/formatters/},          # terminal/markdown/json
    %r{\Alib/archbuddy/review/formatter\.rb\z},      # ReviewContext (R30)
    %r{\Alib/archbuddy/config},                      # config.rb + config/* (C12 validation)
    %r{\Alib/archbuddy/cli/(?:diff|lint)\.rb\z},     # command assembly (R18)
    %r{\Alib/archbuddy/review\.rb\z}                 # require lines only ([S:F4])
  ].freeze

  it "no lib file outside the allowlist mentions calibration" do
    offenders = Dir.chdir(REPO_ROOT_ISOLATION) do
      Dir["lib/**/*.rb"]
        .reject { |f| ALLOWED.any? { |re| f.match?(re) } }
        .select { |f| File.read(f, encoding: "UTF-8").match?(/calibration/i) }
    end
    expect(offenders).to eq([])
  end

  it "review.rb references calibration ONLY on require_relative lines ([S:F4])" do
    lines = File.readlines(File.join(REPO_ROOT_ISOLATION, "lib/archbuddy/review.rb"),
                           encoding: "UTF-8")
            .select { |l| l.match?(/calibration/i) }
    expect(lines).not_to be_empty # the P3-T2 umbrella appends exist
    expect(lines).to all(match(/\A\s*require_relative\s/))
  end

  it "RuleEngine.evaluate accepts no :calibration kwarg (exit-path blindness)" do
    params = Archbuddy::Review::RuleEngine.method(:evaluate).parameters
    expect(params.map(&:last)).not_to include(:calibration)
  end
end
