# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "archbuddy/review"
require "archbuddy/review/git"

# v0.15 P2-T3: Review::Git — pinned merge-base/prefix/archive/worktree
# plumbing over throwaway `git init` repos. Every spec asserts worktree
# hygiene after itself.
RSpec.describe Archbuddy::Review::Git do
  GIT_ENV = {
    "GIT_AUTHOR_NAME" => "spec", "GIT_AUTHOR_EMAIL" => "spec@example.invalid",
    "GIT_COMMITTER_NAME" => "spec", "GIT_COMMITTER_EMAIL" => "spec@example.invalid",
    "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"
  }.freeze

  def git!(dir, *args)
    out, err, status = Open3.capture3(GIT_ENV, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def init_repo(dir)
    git!(dir, "init", "-q", "-b", "main")
    git!(dir, "config", "user.name", "spec")
    git!(dir, "config", "user.email", "spec@example.invalid")
  end

  # A scratch repo with a committed fixture cache (aggregate + one fragment).
  def build_cache_repo(dir)
    init_repo(dir)
    File.write(File.join(dir, "archbuddy-findings.json"), JSON.generate(
                                                            "serializer_version" => 5,
                                                            "sources" => { "lib/a.rb" => { "path" => ".archbuddy/lib/a.rb.json", "shard_mode" => "single" } }
                                                          ))
    FileUtils.mkdir_p(File.join(dir, ".archbuddy/lib"))
    File.write(File.join(dir, ".archbuddy/lib/a.rb.json"), JSON.generate(
                                                             "serializer_version" => 5, "file" => "lib/a.rb",
                                                             "nodes" => [{ "symbol" => "A#x", "branches" => 2 }], "edges" => []
                                                           ))
    File.write(File.join(dir, "lib.rb"), "def x; 1; end\n")
    git!(dir, "add", "-f", ".")
    git!(dir, "commit", "-q", "-m", "cache")
    git!(dir, "rev-parse", "HEAD")
  end

  def expect_worktrees_clean(dir)
    porcelain = git!(dir, "worktree", "list", "--porcelain")
    expect(porcelain.scan(/^worktree /).size).to eq(1)
  end

  around do |example|
    Dir.mktmpdir("archbuddy-git-spec-") do |dir|
      @dir = dir
      example.run
    end
  end

  describe ".repo_root / .prefix" do
    it "resolves the toplevel and a subdir prefix" do
      init_repo(@dir)
      sub = File.join(@dir, "services", "api")
      FileUtils.mkdir_p(sub)
      root = described_class.repo_root(sub)
      expect(File.realpath(root)).to eq(File.realpath(@dir))
      expect(described_class.prefix(sub)).to match(%r{services/api\z})
      expect(described_class.prefix(root)).to eq("")
    end

    it "returns nil outside a git repo" do
      expect(described_class.repo_root(@dir)).to be_nil
      expect(described_class.prefix(@dir)).to be_nil
    end
  end

  describe ".resolve_ref / .default_base_ref / .merge_base" do
    it "resolves refs and picks the first default that exists" do
      sha = build_cache_repo(@dir)
      expect(described_class.resolve_ref(@dir, "main")).to eq(sha)
      expect(described_class.resolve_ref(@dir, "nope")).to be_nil
      expect(described_class.default_base_ref(@dir)).to eq("main")
      expect(described_class.merge_base(@dir, sha)).to eq(sha)
    end

    it "returns nil merge-base for two orphan branches (the exit-2 trigger)" do
      build_cache_repo(@dir)
      git!(@dir, "checkout", "-q", "--orphan", "isolated")
      File.write(File.join(@dir, "other.rb"), "def y; 2; end\n")
      git!(@dir, "add", "-f", ".")
      git!(@dir, "commit", "-q", "-m", "orphan")
      main_sha = described_class.resolve_ref(@dir, "main")
      expect(described_class.merge_base(@dir, main_sha)).to be_nil
    end

    it "returns nil merge-base against a truncated ref in a shallow clone" do
      build_cache_repo(@dir)
      File.write(File.join(@dir, "second.rb"), "def z; 3; end\n")
      git!(@dir, "add", "-f", ".")
      git!(@dir, "commit", "-q", "-m", "second")

      shallow = File.join(@dir, "..", "shallow-#{File.basename(@dir)}")
      begin
        Open3.capture3(GIT_ENV, "git", "clone", "-q", "--depth", "1",
                       "file://#{@dir}", shallow)
        first_sha = git!(@dir, "rev-list", "--max-parents=0", "HEAD")
        expect(described_class.merge_base(shallow, first_sha)).to be_nil
      ensure
        FileUtils.remove_entry(shallow) if File.directory?(shallow)
      end
    end
  end

  describe ".cache_committed_at? / .extract_cache" do
    it "extracts a committed cache byte-equal to the working-tree read" do
      sha = build_cache_repo(@dir)
      expect(described_class.cache_committed_at?(@dir, sha, "")).to be(true)

      Dir.mktmpdir do |dest|
        extracted = described_class.extract_cache(@dir, sha, "", dest)
        expect(extracted).not_to be_nil
        from_extract = Archbuddy::Review::FragmentWalk.read(extracted)
        from_worktree = Archbuddy::Review::FragmentWalk.read(@dir)
        expect(from_extract.by_identity.keys).to eq(from_worktree.by_identity.keys)
        expect(from_extract["lib/a.rb", "A#x"].branches).to eq(2)
      end
    end

    it "extracts a fragment-less committed aggregate without failing" do
      init_repo(@dir)
      File.write(File.join(@dir, "archbuddy-findings.json"),
                 JSON.generate("serializer_version" => 5, "sources" => {}))
      git!(@dir, "add", ".")
      git!(@dir, "commit", "-q", "-m", "aggregate only")
      sha = git!(@dir, "rev-parse", "HEAD")

      Dir.mktmpdir do |dest|
        extracted = described_class.extract_cache(@dir, sha, "", dest)
        expect(extracted).not_to be_nil
        expect(File).to exist(File.join(extracted, "archbuddy-findings.json"))
      end
    end

    it "reports false for a commit without the aggregate" do
      init_repo(@dir)
      File.write(File.join(@dir, "x.rb"), "1\n")
      git!(@dir, "add", ".")
      git!(@dir, "commit", "-q", "-m", "no cache")
      sha = git!(@dir, "rev-parse", "HEAD")
      expect(described_class.cache_committed_at?(@dir, sha, "")).to be(false)
    end
  end

  describe ".worktree_add / .worktree_remove" do
    it "creates and removes a detached worktree, leaving the list clean" do
      sha = build_cache_repo(@dir)
      wt = described_class.worktree_add(@dir, sha)
      expect(wt).not_to be_nil
      expect(File).to exist(File.join(wt, "archbuddy-findings.json"))

      described_class.worktree_remove(@dir, wt)
      expect(File.directory?(wt)).to be(false)
      expect_worktrees_clean(@dir)
    end

    it "returns nil for an unresolvable sha and leaves no tmpdir" do
      build_cache_repo(@dir)
      wt = described_class.worktree_add(@dir, "0" * 40)
      expect(wt).to be_nil
      expect_worktrees_clean(@dir)
    end
  end

  describe ".tracked? / .status_porcelain" do
    it "answers tracking and porcelain over a pathspec" do
      build_cache_repo(@dir)
      expect(described_class.tracked?(@dir, "archbuddy-findings.json")).to be(true)
      expect(described_class.tracked?(@dir, "missing.json")).to be(false)
      expect(described_class.status_porcelain(@dir, ".")).to eq([])

      File.write(File.join(@dir, "lib.rb"), "def x; 2; end\n")
      lines = described_class.status_porcelain(@dir, ".")
      expect(lines.join).to include("lib.rb")
    end
  end

  describe "degenerate: non-git dir" do
    it "degrades to nils without raising" do
      expect(described_class.repo_root(@dir)).to be_nil
      expect(described_class.status_porcelain(@dir, ".")).to eq([])
    end
  end
end
