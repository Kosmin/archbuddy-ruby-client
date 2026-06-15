# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "Capture diagnostics & fail-clear behavior" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  def collect(root)
    Archbuddy::Collect::Registry.for("ruby").new(root, config).collect
  end

  # --- WARNING 1: missing / empty target fails clearly ------------------------

  it "raises NoSourceError for a nonexistent target path" do
    missing = File.join(Dir.tmpdir, "archbuddy-does-not-exist-#{Process.pid}")
    expect { collect(missing) }.to raise_error(
      Archbuddy::Collect::Adapters::Ruby::FileEnumerator::NoSourceError,
      /does not exist/
    )
  end

  it "raises NoSourceError when the target dir contains zero .rb files" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "README.md"), "no ruby here\n")
      expect { collect(dir) }.to raise_error(
        Archbuddy::Collect::Adapters::Ruby::FileEnumerator::NoSourceError,
        /no \.rb files/
      )
    end
  end

  it "raises NoSourceError when a single-file target is not a .rb file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.write(path, "hello\n")
      expect { collect(path) }.to raise_error(
        Archbuddy::Collect::Adapters::Ruby::FileEnumerator::NoSourceError,
        /not a \.rb file/
      )
    end
  end

  it "still succeeds on a directory that does have .rb files" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "thing.rb"), <<~RUBY)
        class Thing
          def go
            helper
          end

          def helper
            1
          end
        end
      RUBY
      expect { collect(dir) }.not_to raise_error
    end
  end

  # --- WARNING 2: metaprogramming sites surface as a diagnostic count ----------

  it "counts metaprogramming call sites as a non-semantic diagnostic" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "meta.rb"), <<~RUBY)
        class Dispatcher
          def run
            send(:work)        # metaprogramming -> no edge, flagged
            public_send(:work) # metaprogramming -> no edge, flagged
          end

          def work
            1
          end
        end
      RUBY

      result = collect(dir)
      expect(result.diagnostics[:meta_sites_skipped]).to eq(2)
    end
  end

  it "reports zero skipped meta sites when there are none" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "plain.rb"), <<~RUBY)
        class Plain
          def a
            b
          end

          def b
            1
          end
        end
      RUBY

      result = collect(dir)
      expect(result.diagnostics[:meta_sites_skipped]).to eq(0)
    end
  end

  it "keeps the meta-site diagnostic OUT of graph node/edge data" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "meta.rb"), <<~RUBY)
        class Dispatcher
          def run
            send(:work)
          end

          def work
            1
          end
        end
      RUBY

      result = collect(dir)
      anon = Archbuddy::Collect::Anonymizer.new(
        result, tool: "archbuddy test", adapter: "ruby"
      ).call

      serialized = ArchitectureAuditor::Contract::Serializer.dump(anon.graph)
      expect(serialized).not_to include("meta_sites")
      expect(serialized).not_to include("metaprogramming")
      # Graph hash itself never carries the diagnostic key.
      expect(anon.graph).not_to have_key("diagnostics")
    end
  end
end
