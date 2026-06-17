# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "archbuddy/cli/report"

# `archbuddy report` with NO args reads the shared `.archbuddy/` workspace:
# FINDINGS defaults to `.archbuddy/findings.yml`, --id-map to
# `.archbuddy/id-map.yml`, --graph to `.archbuddy/graph.yml`. Missing default
# inputs produce a clear, friendly error (not a stack trace). Explicit args/flags
# still override.
RSpec.describe "Archbuddy::CLI::Report default `.archbuddy/` workspace" do
  let(:fixtures)     { File.expand_path("../fixtures/report", __dir__) }
  let(:findings_src) { File.join(fixtures, "findings_fixture.yml") }
  let(:id_map_src)   { File.join(fixtures, "id_map_fixture.yml") }

  def capture(dir, **kwargs)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = nil
    Dir.chdir(dir) do
      begin
        Archbuddy::CLI::Report.new.call(format: "terminal", **kwargs)
      rescue SystemExit => e
        code = e.status
      end
    end
    [out.string, err.string, code]
  ensure
    $stdout = orig_out
    $stderr = orig_err
  end

  it "reads `.archbuddy/{findings,id-map}.yml` with NO args" do
    Dir.mktmpdir do |dir|
      ws = File.join(dir, ".archbuddy")
      FileUtils.mkdir_p(ws)
      FileUtils.cp(findings_src, File.join(ws, "findings.yml"))
      FileUtils.cp(id_map_src, File.join(ws, "id-map.yml"))

      stdout, _stderr, code = capture(dir)

      expect(code).to be_nil # no exit → success
      expect(stdout).to include("OrdersController#create")
    end
  end

  it "prints a friendly error (not a stack trace) when default findings is missing" do
    Dir.mktmpdir do |dir|
      stdout, stderr, code = capture(dir)

      expect(code).to eq(1)
      expect(stderr).to include("no findings at .archbuddy/findings.yml")
      expect(stderr).to include("architecture-auditor analyze")
      expect(stdout).to be_empty
    end
  end

  it "prints a friendly error when default id-map is missing" do
    Dir.mktmpdir do |dir|
      ws = File.join(dir, ".archbuddy")
      FileUtils.mkdir_p(ws)
      FileUtils.cp(findings_src, File.join(ws, "findings.yml"))

      _stdout, stderr, code = capture(dir)

      expect(code).to eq(1)
      expect(stderr).to include("no id-map at .archbuddy/id-map.yml")
      expect(stderr).to include("archbuddy collect")
    end
  end

  it "lets explicit args override the workspace defaults" do
    Dir.mktmpdir do |dir|
      # Empty workspace, but explicit paths point at the fixtures → success.
      stdout, _stderr, code = capture(dir, findings: findings_src, id_map: id_map_src)

      expect(code).to be_nil
      expect(stdout).to include("OrdersController#create")
    end
  end
end
