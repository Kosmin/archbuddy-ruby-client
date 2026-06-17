# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "archbuddy/cli/collect"

# The shared `.archbuddy/` workspace convention: `archbuddy collect .` works with
# NO --out-dir, writing graph.yml + id-map.yml into `.archbuddy/` (relative to
# CWD). The SECRET id-map must stay safe even with this flag-free default:
#   - inside a git repo, the default dir is AUTO-added to .git/info/exclude (a
#     LOCAL ignore — never the tracked .gitignore) so the gitignore-before-secret
#     guard passes and the id-map is git-ignored.
#   - outside a git repo there is no commit risk, so it just writes.
#   - an EXPLICIT non-ignored --out-dir keeps the refuse-guard (we never silently
#     edit ignores for a path the user chose).
RSpec.describe "Archbuddy::CLI::Collect default `.archbuddy/` workspace" do
  # A target WITH an entrypoint under :default so collection always yields nodes.
  HAS_ENTRYPOINT_SRC = <<~RUBY
    def main
      helper
    end

    def helper
      1
    end
  RUBY

  # Run `collect` with CWD chdir'd into `dir`, so the relative `.archbuddy/`
  # default resolves under the tmp dir.
  def run_collect_in(dir, source:, out_dir: nil, entrypoints: "all_public")
    File.write(File.join(dir, "lib.rb"), source)
    stderr = StringIO.new
    orig_stderr = $stderr
    $stderr = stderr
    Dir.chdir(dir) do
      Archbuddy::CLI::Collect.new.call(
        path:               ".",
        out_dir:            out_dir,
        language:           "ruby",
        entrypoints:        entrypoints,
        entrypoint_pattern: []
      )
    end
  ensure
    $stderr = orig_stderr
    yield(stderr.string) if block_given?
  end

  it "writes graph.yml + id-map.yml into `.archbuddy/` with NO --out-dir (non-git dir)" do
    Dir.mktmpdir do |dir|
      run_collect_in(dir, source: HAS_ENTRYPOINT_SRC)

      expect(File).to exist(File.join(dir, ".archbuddy", "graph.yml"))
      expect(File).to exist(File.join(dir, ".archbuddy", "id-map.yml"))
    end
  end

  it "auto-adds `.archbuddy/` to .git/info/exclude and writes the id-map (git repo)" do
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", chdir: dir)

      err = nil
      run_collect_in(dir, source: HAS_ENTRYPOINT_SRC) { |e| err = e }

      exclude = File.join(dir, ".git", "info", "exclude")
      expect(File.read(exclude)).to include(".archbuddy/")
      expect(err).to include(".git/info/exclude")

      # The id-map was written AND is now git-ignored.
      id_map = File.join(dir, ".archbuddy", "id-map.yml")
      expect(File).to exist(id_map)
      Dir.chdir(dir) do
        system("git", "check-ignore", "-q", ".archbuddy/id-map.yml")
        expect($?.success?).to be(true)
      end
    end
  end

  it "is idempotent — a 2nd run does not duplicate the exclude line" do
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", chdir: dir)

      run_collect_in(dir, source: HAS_ENTRYPOINT_SRC)
      run_collect_in(dir, source: HAS_ENTRYPOINT_SRC)

      exclude = File.read(File.join(dir, ".git", "info", "exclude"))
      occurrences = exclude.split("\n").count { |l| l.strip == ".archbuddy/" }
      expect(occurrences).to eq(1)
    end
  end

  it "does NOT touch ignores and KEEPS the refuse-guard for an EXPLICIT non-ignored --out-dir" do
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", chdir: dir)

      # Force the Emitter's filename fallback off so an explicit, non-ignored
      # out-dir actually triggers the gitignore-before-secret refusal — proving
      # the existing guard is unchanged for user-chosen paths.
      allow_any_instance_of(Archbuddy::Collect::Emitter)
        .to receive(:filename_ignored?).and_return(false)

      expect {
        run_collect_in(dir, source: HAS_ENTRYPOINT_SRC, out_dir: File.join(dir, "exports"))
      }.to raise_error(Archbuddy::Collect::Emitter::SecretNotIgnoredError)

      # And we did NOT modify .git/info/exclude for the user-chosen path.
      exclude = File.join(dir, ".git", "info", "exclude")
      contents = File.exist?(exclude) ? File.read(exclude) : ""
      expect(contents).not_to include("exports")
    end
  end
end
