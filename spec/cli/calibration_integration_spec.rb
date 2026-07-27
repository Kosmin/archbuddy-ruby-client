# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require "archbuddy/cli"

# v0.15 P3-T2: calibration end-to-end through the shipped lint command —
# exit-code invariance (calibration on vs off, same findings ⇒ same exit,
# proven on the UseCaseComplexity ep-rule path too, [D3]) and the dishonest
# local-block config error.
RSpec.describe "calibration integration (lint end-to-end)" do
  # The T7 controller fixture: 6-decision guard-style action → branches 64
  # (2^6 > 2^5) → UseCaseComplexity warn finding with the Q4 clause.
  def build_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app", "main.rb"), <<~RUBY)
      class FooController
        def show
          x = 1 if p1
          x = 2 if p2
          x = 3 if p3
          x = 4 if p4
          x = 5 if p5
          x = 6 if p6
          :ok
        end
      end
    RUBY
    dir
  end

  def run_lint(**kwargs)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = nil
    begin
      Archbuddy::CLI::Lint.new.call(**kwargs)
    rescue SystemExit => e
      code = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [code, out.string, err.string]
  end

  it "exit-code invariance: builtin renders L-UC-Q4, none renders [], SAME exit" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)

      # Run A — builtin calibration (no calibration block), gating at warn.
      code_builtin, stdout_builtin, = run_lint(target: dir, format: "json",
                                               fail_level: "warn")
      doc_builtin = JSON.parse(stdout_builtin)
      expect(doc_builtin["findings"].map { |f| f["rule"] })
        .to include("UseCaseComplexity")
      expect(doc_builtin["calibration"]["source"]).to eq("builtin-study-v1")
      expect(doc_builtin["calibration"]["lines"])
        .to include(a_string_matching(/use case\(s\) contain a node above the Q4 boundary/))

      # Run B — source: none suppresses every line.
      File.write(File.join(dir, ".archbuddy.yml"), <<~YAML)
        version: 1
        calibration:
          source: none
      YAML
      code_none, stdout_none, = run_lint(target: dir, format: "json",
                                         fail_level: "warn")
      doc_none = JSON.parse(stdout_none)
      expect(doc_none["calibration"]["source"]).to eq("none")
      expect(doc_none["calibration"]["lines"]).to eq([])
      expect(doc_none["findings"].map { |f| f["rule"] })
        .to include("UseCaseComplexity")

      # The observable form of "never a gate input": same findings ⇒ same exit.
      expect(code_none).to eq(code_builtin)
      expect(code_builtin).to eq(1) # warn finding gates at --fail-level warn
    end
  end

  it "source: local without provenance → exit 2 naming calibration.provenance" do
    Dir.mktmpdir do |dir|
      build_fixture(dir)
      File.write(File.join(dir, ".archbuddy.yml"), <<~YAML)
        version: 1
        calibration:
          source: local
      YAML
      code, stdout, stderr = run_lint(target: dir, format: "json")
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to match(/\Aerror:/)
      expect(stderr).to include("calibration.provenance")
    end
  end
end
