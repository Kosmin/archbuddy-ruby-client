# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "archbuddy/cli"
require "archbuddy/cli/collect"
require "archbuddy/cli/reset"
require "archbuddy/cache/layout"

# v0.9 W1: the committed cache HONORS THE TARGET PATH ARGUMENT — it is written
# to/read from the TARGET repo (the codebase path arg), NOT the current working
# directory. Historically the CLI hardcoded `project_root: Dir.pwd`, so running
# `archbuddy collect <target>` (or `reset`/`analyze`) from ANY OTHER directory
# wrote the cache into the wrong place. These specs run each command from a CWD
# DIFFERENT than the target and assert the `.archbuddy/` committed cache lands in
# the TARGET, and NOT in the CWD.
RSpec.describe "committed cache honors the target path arg (v0.9 W1)" do
  ROOT_AGG = Archbuddy::Cache::Layout::ROOT_AGGREGATE

  def seed_target(dir)
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app/x.rb"), "class X\n  def run\n    helper\n  end\n\n  def helper\n    1\n  end\nend\n")
  end

  # Run a block with $stderr silenced (the commands are chatty on stderr).
  def quiet
    orig = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = orig
  end

  describe "`archbuddy collect <target>` from a different CWD" do
    it "writes the committed cache into the TARGET, not the CWD" do
      Dir.mktmpdir do |cwd|
        Dir.mktmpdir do |target|
          seed_target(target)

          quiet do
            Dir.chdir(cwd) do
              Archbuddy::CLI::Collect.new.call(
                path: target, out_dir: nil, language: "ruby",
                entrypoints: "all_public", entrypoint_pattern: []
              )
            end
          end

          # Committed cache lands in the TARGET.
          expect(File).to exist(File.join(target, ROOT_AGG))
          expect(Dir).to exist(File.join(target, Archbuddy::Cache::Layout::DETAIL_DIR))
          # The detail-tree fragment for the seeded source is under the target.
          expect(File).to exist(File.join(target, ".archbuddy", "app/x.rb.json"))

          # Nothing was written into the CWD.
          expect(File).not_to exist(File.join(cwd, ROOT_AGG))
          expect(File).not_to exist(File.join(cwd, ".archbuddy", "app/x.rb.json"))
        end
      end
    end
  end

  describe "`archbuddy reset <target>` from a different CWD" do
    it "writes the committed real-name aggregate into the TARGET, not the CWD" do
      Dir.mktmpdir do |cwd|
        Dir.mktmpdir do |target|
          seed_target(target)

          quiet do
            Dir.chdir(cwd) do
              Archbuddy::CLI::Reset.new.call(path: target, entrypoints: "all_public")
            end
          end

          agg_path = File.join(target, ROOT_AGG)
          expect(File).to exist(agg_path)
          # reset ran a full analyze → the committed aggregate carries a scores block.
          doc = JSON.parse(File.read(agg_path))
          expect(doc).to have_key("scores")
          # Real-name detail tree is in the target too.
          expect(File).to exist(File.join(target, ".archbuddy", "app/x.rb.json"))

          # CWD stays clean.
          expect(File).not_to exist(File.join(cwd, ROOT_AGG))
          expect(File).not_to exist(File.join(cwd, ".archbuddy"))
        end
      end
    end
  end

  describe "the default-workspace behavior is preserved when the target IS the CWD" do
    it "`collect .` writes the committed cache into the current directory" do
      Dir.mktmpdir do |dir|
        seed_target(dir)
        quiet do
          Dir.chdir(dir) do
            Archbuddy::CLI::Collect.new.call(
              path: ".", out_dir: nil, language: "ruby",
              entrypoints: "all_public", entrypoint_pattern: []
            )
          end
        end
        expect(File).to exist(File.join(dir, ROOT_AGG))
        expect(File).to exist(File.join(dir, ".archbuddy", "app/x.rb.json"))
      end
    end
  end
end
