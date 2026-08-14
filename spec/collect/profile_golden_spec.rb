# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "support/golden_corpus"

# THE PURITY GATE (configurator W2).
#
# The profile migration moved the collector's ecosystem vocabulary out of
# hardcoded Ruby constants and into the engine-shipped `ruby.rails` profile
# document. That is a DATA MOVE, so its correctness criterion is total: the
# emitted bytes must not change.
#
# These goldens were generated from PRE-migration code and committed. They are
# NOT env-gated — an env-gated golden rots, and the whole point of this gate is
# that it runs on every suite run.
#
# Discriminating power (verified by mutation): removing a single ORM verb from
# the profile, or folding the `Aws::` egress prefix into the exact-root list,
# changes these bytes.
RSpec.describe "profile migration golden" do
  Archbuddy::GoldenCorpus.corpora.each_key do |corpus|
    describe "corpus #{corpus.inspect}" do
      let(:captured) { Archbuddy::GoldenCorpus.capture(corpus) }

      it "emits bytes identical to the committed pre-migration golden" do
        captured.each do |artifact, bytes|
          path = Archbuddy::GoldenCorpus.golden_path(corpus, artifact)

          expect(File.file?(path)).to be(true),
                                      "missing committed golden #{path} — regenerate deliberately, never on drift"
          expect(bytes).to eq(File.read(path)),
                           "#{corpus}.#{artifact} drifted from the committed golden"
        end
      end
    end
  end

  # The gate-passes / population-empties cell. TWO distinct empties, and the
  # shipped collector treats them differently — deliberately:
  #
  #   no Ruby sources at all -> FileEnumerator raises NoSourceError (LOUD; the
  #     CLI catches it and exits 1). "I found nothing to read" must never be
  #     reported as "I read everything and it was empty".
  #   Ruby sources that define nothing -> a clean, empty capture.
  it "refuses a root with no Ruby sources rather than reporting an empty capture" do
    Dir.mktmpdir("archbuddy-golden-empty") do |dir|
      File.write(File.join(dir, "README.md"), "no ruby here\n")

      config = Archbuddy::Collect::Config.new(language: "ruby")

      expect { Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect }
        .to raise_error(Archbuddy::Collect::Adapters::Ruby::FileEnumerator::NoSourceError)
    end
  end

  # `add_external_sinks` mints the generic sink unconditionally, so ONE
  # external node is the honest floor for a definition-free capture — not zero.
  it "collects a definition-free root to a single external sink, no nodes, no edges, no entrypoints" do
    Dir.mktmpdir("archbuddy-golden-bare") do |dir|
      File.write(File.join(dir, "bare.rb"), "# no definitions here\n")

      config = Archbuddy::Collect::Config.new(language: "ruby")
      result = nil

      expect { result = Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect }
        .not_to raise_error

      expect(result.nodes.count { |n| n.kind.to_s == "function" }).to eq(0)
      expect(result.nodes.count { |n| n.kind.to_s == "external" }).to eq(1)
      expect(result.edges).to be_empty
      expect(result.entrypoints).to be_empty
    end
  end
end
