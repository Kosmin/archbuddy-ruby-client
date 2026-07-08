# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "archbuddy/cli/collect"

# C3 (g): after a default-workspace collect in an audited repo, the SECRET/
# machine-local paths stay gitignored (`git check-ignore` succeeds) while the
# committed real-name parts are staged by `git add -A`.
RSpec.describe "secret gitignore boundary end-to-end (C3)" do
  def run_collect(dir)
    stderr = StringIO.new
    orig = $stderr
    $stderr = stderr
    Dir.chdir(dir) do
      Archbuddy::CLI::Collect.new.call(
        path: ".", out_dir: nil, language: "ruby",
        entrypoints: "all_public", entrypoint_pattern: []
      )
    end
  ensure
    $stderr = orig
  end

  def check_ignored?(dir, rel)
    Dir.chdir(dir) { system("git", "check-ignore", "-q", rel) }
    $?.success?
  end

  it "keeps id-map.yml + .cache/ ignored; stages the committed real-name cache" do
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", chdir: dir)
      system("git", "-C", dir, "config", "user.email", "t@t")
      system("git", "-C", dir, "config", "user.name", "t")
      FileUtils.mkdir_p(File.join(dir, "app"))
      File.write(File.join(dir, "app/x.rb"), "def main\n  helper\nend\n\ndef helper\n  1\nend\n")

      run_collect(dir)
      # Materialize the speed cache so its ignore is exercised too.
      FileUtils.mkdir_p(File.join(dir, ".archbuddy/.cache"))
      File.write(File.join(dir, ".archbuddy/.cache/x.bin"), "blob")

      # SECRET + machine-local: ignored.
      expect(check_ignored?(dir, ".archbuddy/id-map.yml")).to be(true)
      expect(check_ignored?(dir, ".archbuddy/.cache/x.bin")).to be(true)
      expect(check_ignored?(dir, ".archbuddy/graph.yml")).to be(true)

      # Committed real-name parts: NOT ignored → staged by git add -A.
      system("git", "-C", dir, "add", "-A")
      staged = IO.popen(["git", "-C", dir, "diff", "--cached", "--name-only"], &:read).split("\n")
      expect(staged).to include("archbuddy-findings.json")
      expect(staged.any? { |f| f.start_with?(".archbuddy/app/") }).to be(true)
      # No secret staged.
      expect(staged).not_to include(".archbuddy/id-map.yml")
      expect(staged.none? { |f| f.include?(".archbuddy/.cache/") }).to be(true)
    end
  end
end
