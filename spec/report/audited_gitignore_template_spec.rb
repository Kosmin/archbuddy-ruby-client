# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# R2-2: the AUDITED-repo `.gitignore` TEMPLATE. When an audited repo copies the
# shipped template into its tracked `.gitignore`, git must:
#   * KEEP ignored: .archbuddy/id-map.yml (SECRET), .archbuddy/.cache/,
#     the opaque interchange (graph.yml/findings.yml), and report.* exports.
#   * NOT ignore (stage): the root archbuddy-findings.json aggregate and the
#     .archbuddy/<mirrored-source> real-name detail tree.
# This is verified with a REAL `git check-ignore` against a real repo — the
# negation-pattern ordering is subtle, so we assert it empirically.
RSpec.describe "audited-repo .gitignore template (R2-2)" do
  let(:template) { File.expand_path("../../templates/audited-repo.gitignore", __dir__) }

  def check_ignored?(dir, rel)
    system("git", "-C", dir, "check-ignore", "-q", rel)
    $?.success?
  end

  around do |example|
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", chdir: dir)
      # Copy the shipped template into the audited repo's TRACKED .gitignore.
      FileUtils.cp(template, File.join(dir, ".gitignore"))
      # Materialize a representative committed + secret layout.
      FileUtils.mkdir_p(File.join(dir, ".archbuddy/app/models"))
      FileUtils.mkdir_p(File.join(dir, ".archbuddy/.cache"))
      File.write(File.join(dir, "archbuddy-findings.json"), "{}")
      File.write(File.join(dir, ".archbuddy/app/models/user.rb.json"), "{}")
      File.write(File.join(dir, ".archbuddy/id-map.yml"), "ids: {}")
      File.write(File.join(dir, ".archbuddy/graph.yml"), "nodes: []")
      File.write(File.join(dir, ".archbuddy/findings.yml"), "nodes: {}")
      File.write(File.join(dir, ".archbuddy/.cache/blob.bin"), "x")
      File.write(File.join(dir, ".archbuddy/report.html"), "<html>")
      @dir = dir
      example.run
    end
  end

  it "keeps the SECRET id-map ignored" do
    expect(check_ignored?(@dir, ".archbuddy/id-map.yml")).to be(true)
  end

  it "keeps the machine-local .cache/ ignored" do
    expect(check_ignored?(@dir, ".archbuddy/.cache/blob.bin")).to be(true)
  end

  it "keeps the opaque interchange (graph.yml/findings.yml) ignored" do
    expect(check_ignored?(@dir, ".archbuddy/graph.yml")).to be(true)
    expect(check_ignored?(@dir, ".archbuddy/findings.yml")).to be(true)
  end

  it "keeps de-anonymized report.* exports ignored" do
    expect(check_ignored?(@dir, ".archbuddy/report.html")).to be(true)
  end

  it "does NOT ignore the committed root aggregate" do
    expect(check_ignored?(@dir, "archbuddy-findings.json")).to be(false)
  end

  it "does NOT ignore the committed real-name detail tree" do
    expect(check_ignored?(@dir, ".archbuddy/app/models/user.rb.json")).to be(false)
  end

  it "stages exactly the committed cache (git add -A) — no secret staged" do
    system("git", "-C", @dir, "config", "user.email", "t@t")
    system("git", "-C", @dir, "config", "user.name", "t")
    system("git", "-C", @dir, "add", "-A")
    staged = IO.popen(["git", "-C", @dir, "diff", "--cached", "--name-only"], &:read).split("\n")
    expect(staged).to include("archbuddy-findings.json")
    expect(staged).to include(".archbuddy/app/models/user.rb.json")
    expect(staged).not_to include(".archbuddy/id-map.yml")
    expect(staged.none? { |f| f.include?(".archbuddy/.cache/") }).to be(true)
    expect(staged).not_to include(".archbuddy/graph.yml")
    expect(staged).not_to include(".archbuddy/report.html")
  end
end
