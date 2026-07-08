# frozen_string_literal: true

require "archbuddy/cache"
require "tmpdir"
require "fileutils"

# C2: incremental collect — content-hash-per-fragment authoritative change
# trigger + verbatim reuse of unchanged files' parses from the machine-local
# `.archbuddy/.cache/`. mtime is NEVER consulted. A collector-version mismatch
# forces re-parse. incremental result == full recompute for the changed set.
RSpec.describe "incremental collect (C2)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def write_sources(dir)
    FileUtils.mkdir_p(File.join(dir, "app"))
    File.write(File.join(dir, "app/a.rb"), <<~RUBY)
      class A
        def run
          B.new.go
        end
      end
    RUBY
    File.write(File.join(dir, "app/b.rb"), <<~RUBY)
      class B
        def go
          1 + 1
        end
      end
    RUBY
  end

  def adapter_for(dir)
    Archbuddy::Collect::Registry.for("ruby").new(dir, config)
  end

  def serialized(adapter_result)
    anon = Archbuddy::Collect::Anonymizer.new(
      adapter_result, tool: "archbuddy test", adapter: "ruby"
    ).call
    ArchitectureAuditor::Contract::Serializer.dump(anon.graph)
  end

  it "reuses an unchanged file's parse verbatim (no re-parse) via the speed cache" do
    Dir.mktmpdir do |dir|
      write_sources(dir)
      # Prime the cache with a full-mode-equivalent incremental run.
      adapter_for(dir).collect(mode: :incremental)

      # On the second incremental run, Prism.parse must NOT be called for either
      # file (both hashes + versions match the primed cache blobs).
      expect(Prism).not_to receive(:parse)
      adapter_for(dir).collect(mode: :incremental)
    end
  end

  it "re-parses ONLY the changed file; unchanged fragment reused byte-identically" do
    Dir.mktmpdir do |dir|
      write_sources(dir)
      adapter_for(dir).collect(mode: :incremental) # prime

      # Edit only app/a.rb.
      File.write(File.join(dir, "app/a.rb"), <<~RUBY)
        class A
          def run
            B.new.go
            B.new.go
          end
        end
      RUBY

      # Exactly one Prism.parse (app/a.rb); app/b.rb is reused from cache.
      expect(Prism).to receive(:parse).once.and_call_original
      adapter_for(dir).collect(mode: :incremental)
    end
  end

  it "incremental result == full recompute for the changed set" do
    Dir.mktmpdir do |dir|
      write_sources(dir)
      adapter_for(dir).collect(mode: :incremental) # prime

      # Change a file, then compare incremental vs a from-scratch full parse.
      File.write(File.join(dir, "app/b.rb"), <<~RUBY)
        class B
          def go
            2 + 2
          end
        end
      RUBY

      incremental = serialized(adapter_for(dir).collect(mode: :incremental))
      full        = serialized(adapter_for(dir).collect(mode: :full))
      expect(incremental).to eq(full)
    end
  end

  it "drops the fragment of a deleted source file (it no longer enumerates)" do
    Dir.mktmpdir do |dir|
      write_sources(dir)
      adapter_for(dir).collect(mode: :incremental) # prime (cache holds a.rb + b.rb)

      FileUtils.rm(File.join(dir, "app/b.rb"))
      result = adapter_for(dir).collect(mode: :incremental)
      symbols = result.nodes.map(&:symbol)
      expect(symbols).to include("A#run")
      expect(symbols).not_to include("B#go") # dropped
    end
  end

  it "empty/stale cache in :incremental mode degrades to a full parse (not an empty graph)" do
    Dir.mktmpdir do |dir|
      write_sources(dir)
      # No priming → every file misses the reuse gate → full parse.
      result = adapter_for(dir).collect(mode: :incremental)
      expect(result.nodes.map(&:symbol)).to include("A#run", "B#go")
    end
  end

  it "NEVER consults mtime (touch alone does not force a re-parse)" do
    Dir.mktmpdir do |dir|
      write_sources(dir)
      adapter_for(dir).collect(mode: :incremental) # prime

      # touch bumps mtime WITHOUT changing content → content hash unchanged →
      # reuse (no re-parse). If mtime were consulted this would re-parse.
      future = Time.now + 3600
      FileUtils.touch(File.join(dir, "app/a.rb"), mtime: future)
      FileUtils.touch(File.join(dir, "app/b.rb"), mtime: future)

      expect(Prism).not_to receive(:parse)
      adapter_for(dir).collect(mode: :incremental)
    end
  end

  it "the change detector source references no mtime (grep guard)" do
    src = File.read(File.expand_path("../../lib/archbuddy/cache/change_detector.rb", __dir__), encoding: "UTF-8")
    src += File.read(File.expand_path("../../lib/archbuddy/cache/reader.rb", __dir__), encoding: "UTF-8")
    expect(src).not_to match(/File\.mtime|\.mtime\b|File\.stat/)
  end

  # C2 COLLECTOR-VERSION STAMP: a cache blob written by an OLDER collector is NOT
  # reused even when the source is byte-identical → forces re-parse.
  it "forces re-parse on a collector-version mismatch (stale-blob guard)" do
    Dir.mktmpdir do |dir|
      write_sources(dir)
      reader = Archbuddy::Cache::Reader.new(project_root: dir)
      source = File.read(File.join(dir, "app/a.rb"))
      hash   = Archbuddy::Cache::ChangeDetector.content_hash(source)

      # A blob with a matching content hash but a DIFFERENT collector version
      # must NOT be reused (returns nil → caller re-parses).
      stale = Marshal.dump(
        collector_version: Archbuddy::Cache::Reader::COLLECTOR_VERSION - 1,
        content_hash:      hash,
        parsed_value:      Prism.parse(source).value
      )
      # Prime the real blob, then overwrite it with a stale-version blob.
      reader.store("app/a.rb", hash, Prism.parse(source).value)
      real_path = Dir.glob(File.join(dir, ".archbuddy/.cache/*.bin"))
                     .find { |p| Marshal.load(File.binread(p))[:content_hash] == hash }
      File.binwrite(real_path, stale)

      expect(reader.reuse("app/a.rb", hash)).to be_nil
    end
  end
end
