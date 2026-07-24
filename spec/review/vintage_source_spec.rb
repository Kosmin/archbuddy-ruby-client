# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "archbuddy"
require "archbuddy/review"

# v0.15 P2-T7: Review::VintageSource — committed/stateless/injected base
# precedence + P6 head staleness, every pinned message asserted verbatim.
RSpec.describe Archbuddy::Review::VintageSource do
  GitMod = Archbuddy::Review::Git

  VS_GIT_ENV = {
    "GIT_AUTHOR_NAME" => "spec", "GIT_AUTHOR_EMAIL" => "spec@example.invalid",
    "GIT_COMMITTER_NAME" => "spec", "GIT_COMMITTER_EMAIL" => "spec@example.invalid",
    "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"
  }.freeze

  def git!(dir, *args)
    out, err, status = Open3.capture3(VS_GIT_ENV, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def init_repo(dir)
    git!(dir, "init", "-q", "-b", "main")
    git!(dir, "config", "user.name", "spec")
    git!(dir, "config", "user.email", "spec@example.invalid")
  end

  def write_source(dir)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib/thing.rb"), <<~RUBY)
      class Thing
        def choose(a, b)
          if a
            1
          elsif b
            2
          else
            3
          end
        end
      end
    RUBY
  end

  def write_cache(dir)
    File.write(File.join(dir, "archbuddy-findings.json"), JSON.generate(
                                                            "serializer_version" => 5,
                                                            "sources" => { "lib/a.rb" => {
                                                              "path" => ".archbuddy/lib/a.rb.json", "shard_mode" => "single"
                                                            } }
                                                          ))
    FileUtils.mkdir_p(File.join(dir, ".archbuddy/lib"))
    File.write(File.join(dir, ".archbuddy/lib/a.rb.json"), JSON.generate(
                                                             "serializer_version" => 5, "file" => "lib/a.rb",
                                                             "nodes" => [{ "symbol" => "A#x", "branches" => 2, "entrypoint" => false }],
                                                             "edges" => []
                                                           ))
  end

  def write_empty_cache(dir)
    File.write(File.join(dir, "archbuddy-findings.json"),
               JSON.generate("serializer_version" => 5, "sources" => {}))
  end

  def expect_worktrees_clean(dir)
    porcelain = git!(dir, "worktree", "list", "--porcelain")
    expect(porcelain.scan(/^worktree /).size).to eq(1)
  end

  def quiet_stderr
    orig = $stderr
    $stderr = StringIO.new
    result = yield
    [result, $stderr.string]
  ensure
    $stderr = orig
  end

  around do |example|
    Dir.mktmpdir("archbuddy-vs-spec-") do |dir|
      @dir = File.realpath(dir) # macOS /var → /private/var (match git's toplevel)
      @scratch = File.join(dir, "scratch")
      FileUtils.mkdir_p(@scratch)
      example.run
    end
  end

  describe ".base" do
    it "prefers the committed cache at the merge-base — no worktree created" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      init_repo(repo)
      write_cache(repo)
      write_source(repo)
      git!(repo, "add", "-f", ".")
      git!(repo, "commit", "-q", "-m", "cache")

      expect(GitMod).not_to receive(:worktree_add)
      (vintage, label), err = quiet_stderr do
        described_class.base(target: repo, base_ref: "main", scratch: @scratch)
      end

      expect(label[:vintage]).to eq("committed-cache")
      expect(label[:ref]).to eq("main")
      expect(label[:sha]).to eq(git!(repo, "rev-parse", "HEAD"))
      expect(vintage["lib/a.rb", "A#x"]).not_to be_nil
      expect(err).to match(/note: base vintage from committed cache at [0-9a-f]{7}/)
    end

    it "falls back to a stateless worktree collect — worktree created AND removed" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      init_repo(repo)
      write_source(repo)
      git!(repo, "add", ".")
      git!(repo, "commit", "-q", "-m", "source only")

      (vintage, label), err = quiet_stderr do
        described_class.base(target: repo, base_ref: "main", scratch: @scratch)
      end

      expect(label[:vintage]).to eq("stateless-collect")
      expect(err).to match(
        /note: no committed archbuddy cache at [0-9a-f]{7} — collecting base in a temporary worktree/
      )
      expect_worktrees_clean(repo)

      direct = Dir.mktmpdir("archbuddy-vs-direct-") do |write_root|
        Archbuddy::Review::Collector.collect(source_root: repo, write_root: write_root)
        Archbuddy::Review::FragmentWalk.read(write_root)
      end
      expect(vintage.nodes.map(&:symbol).sort).to eq(direct.nodes.map(&:symbol).sort)
      expect(vintage.nodes.map(&:symbol)).not_to be_empty
    end

    it "injects --base-cache without touching git at all" do
      fixture = File.expand_path("../fixtures/review/vintages/exported_layout", __dir__)
      GitMod.public_methods(false).each do |m|
        allow(GitMod).to receive(m) { raise "git touched (#{m})" }
      end

      (vintage, label), _err = quiet_stderr do
        described_class.base(target: @dir, base_ref: "label-only", base_cache: fixture,
                             scratch: @scratch)
      end

      expect(label).to eq(ref: "label-only", sha: nil, vintage: "injected-dir")
      expect(vintage.nodes).not_to be_empty
    end

    it "emits the loud empty-base note on a committed empty aggregate" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      init_repo(repo)
      write_empty_cache(repo)
      write_source(repo)
      git!(repo, "add", "-f", ".")
      git!(repo, "commit", "-q", "-m", "empty cache")

      (vintage, _label), err = quiet_stderr do
        described_class.base(target: repo, base_ref: "main", scratch: @scratch)
      end

      expect(vintage).to be_empty
      expect(err).to include("note: base vintage is empty (0 nodes) — all head nodes count as NEW")
    end

    it "pins every error message" do
      plain = File.join(@dir, "plain")
      FileUtils.mkdir_p(plain)
      expect do
        quiet_stderr { described_class.base(target: plain, scratch: @scratch) }
      end.to raise_error(Archbuddy::Review::VintageError,
                         /error: '.*' is not inside a git repository; pass --base-cache DIR or run inside a git checkout/)

      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      init_repo(repo)
      write_source(repo)
      git!(repo, "add", ".")
      git!(repo, "commit", "-q", "-m", "c1")

      expect do
        quiet_stderr { described_class.base(target: repo, base_ref: "nope", scratch: @scratch) }
      end.to raise_error(Archbuddy::Review::VintageError, /error: cannot resolve base ref 'nope'/)

      # orphan branch shares no history with main → no merge-base
      git!(repo, "checkout", "-q", "--orphan", "orphan")
      File.write(File.join(repo, "other.rb"), "class Other; end\n")
      git!(repo, "add", ".")
      git!(repo, "commit", "-q", "-m", "orphan")
      git!(repo, "checkout", "-q", "main")
      expect do
        quiet_stderr { described_class.base(target: repo, base_ref: "orphan", scratch: @scratch) }
      end.to raise_error(Archbuddy::Review::VintageError,
                         /error: no merge-base between 'orphan' and HEAD — shallow clone\? fetch full history \(fetch-depth: 0\) or git fetch --unshallow/)

      # default-ref failure: a repo whose only branch is 'trunk'
      trunk = File.join(@dir, "trunk-repo")
      FileUtils.mkdir_p(trunk)
      git!(trunk, "init", "-q", "-b", "trunk")
      git!(trunk, "config", "user.name", "spec")
      git!(trunk, "config", "user.email", "spec@example.invalid")
      File.write(File.join(trunk, "a.rb"), "class A; end\n")
      git!(trunk, "add", ".")
      git!(trunk, "commit", "-q", "-m", "c1")
      expect do
        quiet_stderr { described_class.base(target: trunk, scratch: @scratch) }
      end.to raise_error(Archbuddy::Review::VintageError,
                         /error: cannot determine a default base ref \(tried origin\/main, origin\/master, main, master\); pass BASE_REF explicitly/)

      empty_cache_dir = File.join(@dir, "no-aggregate")
      FileUtils.mkdir_p(empty_cache_dir)
      expect do
        described_class.base(target: repo, base_cache: empty_cache_dir, scratch: @scratch)
      end.to raise_error(Archbuddy::Review::VintageError,
                         /error: --base-cache .* does not contain archbuddy-findings\.json/)
    end
  end

  describe ".head" do
    it "reuses a tracked + clean working-tree cache with the pinned note" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      init_repo(repo)
      write_cache(repo)
      write_source(repo)
      git!(repo, "add", "-f", ".")
      git!(repo, "commit", "-q", "-m", "all committed")

      (vintage, label), err = quiet_stderr do
        described_class.head(target: repo, scratch: @scratch)
      end

      expect(label[:vintage]).to eq("working-tree-cache")
      expect(label[:dirty]).to be(false)
      expect(label[:sha]).to eq(git!(repo, "rev-parse", "HEAD"))
      expect(vintage["lib/a.rb", "A#x"]).not_to be_nil
      expect(err).to include("note: head vintage from committed working-tree cache (tracked + clean)")
    end

    it "re-collects a dirty tracked cache with the pinned re-collect note" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      init_repo(repo)
      write_cache(repo)
      write_source(repo)
      git!(repo, "add", "-f", ".")
      git!(repo, "commit", "-q", "-m", "all committed")
      File.write(File.join(repo, "lib/thing.rb"), "class Thing; def z; 1; end; end\n")

      (vintage, label), err = quiet_stderr do
        described_class.head(target: repo, scratch: @scratch)
      end

      expect(label[:vintage]).to eq("fresh-collect")
      expect(label[:dirty]).to be(true)
      expect(err).to include(
        "note: working-tree cache is not verifiably fresh — re-collecting head " \
        "(commit the cache and pair with 'archbuddy collect --check', or run " \
        "'archbuddy collect .' to refresh the manifest)"
      )
      expect(vintage["lib/a.rb", "A#x"]).to be_nil # freshly collected, not the stale cache
    end

    it "reuses an untracked cache when the manifest verifies fresh" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      init_repo(repo)
      write_source(repo)
      git!(repo, "add", ".")
      git!(repo, "commit", "-q", "-m", "source only")
      write_cache(repo) # untracked
      Archbuddy::Cache::CollectManifest.write(project_root: repo, files: ["lib/thing.rb"])

      (vintage, label), err = quiet_stderr do
        described_class.head(target: repo, scratch: @scratch)
      end

      expect(label[:vintage]).to eq("working-tree-cache")
      expect(vintage["lib/a.rb", "A#x"]).not_to be_nil
      expect(err).to include("note: head vintage from working-tree cache (manifest-verified fresh)")
    end

    it "re-collects an untracked cache without a manifest" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      init_repo(repo)
      write_source(repo)
      git!(repo, "add", ".")
      git!(repo, "commit", "-q", "-m", "source only")
      write_cache(repo) # untracked, no manifest

      (_vintage, label), _err = quiet_stderr do
        described_class.head(target: repo, scratch: @scratch)
      end

      expect(label[:vintage]).to eq("fresh-collect")
    end

    it "trusts the cache loudly (exactly one warning) on a non-git cache-only dir" do
      dir = File.join(@dir, "cache-only")
      FileUtils.mkdir_p(dir)
      write_cache(dir)

      (vintage, label), err = quiet_stderr do
        described_class.head(target: dir, trust_cache: true, scratch: @scratch)
      end

      expect(label[:vintage]).to eq("trusted-cache")
      expect(label[:sha]).to be_nil
      expect(vintage["lib/a.rb", "A#x"]).not_to be_nil
      warning = "warning: --trust-cache: using the working-tree cache WITHOUT a freshness " \
                "check — findings may not reflect current sources"
      expect(err.scan(warning).size).to eq(1)
    end

    it "raises the pinned error when --trust-cache finds no cache" do
      dir = File.join(@dir, "empty")
      FileUtils.mkdir_p(dir)
      expect do
        described_class.head(target: dir, trust_cache: true, scratch: @scratch)
      end.to raise_error(Archbuddy::Review::VintageError,
                         /error: --trust-cache given but no archbuddy-findings\.json at /)
    end

    it "falls through to re-collect on a plain non-git target (no cache)" do
      dir = File.join(@dir, "plain")
      FileUtils.mkdir_p(dir)
      write_source(dir)

      (vintage, label), _err = quiet_stderr do
        described_class.head(target: dir, scratch: @scratch)
      end

      expect(label).to eq(sha: nil, vintage: "fresh-collect", dirty: false)
      expect(vintage.nodes).not_to be_empty
    end
  end
end
