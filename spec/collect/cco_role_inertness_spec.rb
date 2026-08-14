# frozen_string_literal: true

require "spec_helper"
require "support/golden_corpus"
require "json"
require "tempfile"
require "tmpdir"
require "fileutils"
require "stringio"
require "architecture_auditor/cli"

# THE W3 GATE — TWO QUESTIONS, AND THEY SETTLE IT.
#
#   1. ZERO COUNT CHANGE. The tag is ADDITIVE: it may add a KEY, never a node,
#      an edge or an entrypoint.
#   2. THE TAG IS INERT. Nothing reads it to decide anything.
#
# The ENGINE half of (2) already ships — spec/analyze/cco_role_backdoor_lock_spec.rb
# proves `cco_role` appears nowhere under the processor and that stamping every
# node with every role value leaves the findings byte-identical. THIS FILE IS
# THE CLIENT HALF: no client scoring or ranking path reads it, and a role-value
# mutation driven through the REAL pipeline (collect -> graph -> engine analyze)
# moves no published number.
#
# WHY THE ADDITIVITY GATE IS NOT "REGENERATE AND EYEBALL THE DIFF". A one-time
# diff proves the claim once, on the day it is made, and then rots. Every corpus
# below is captured TWICE in-process — once through the shipped rev-1.1 profile
# and once through the SAME profile with every `role` key removed (which is
# exactly a rev-1.0 document) — and the two captures are compared structurally.
# That makes "the only delta is the appearance of cco_role keys" an executable,
# permanent statement rather than a historical observation.
RSpec.describe "cco_role is ADDITIVE and INERT (W3 gate)" do
  RUBY_NS  = Archbuddy::Collect::Adapters::Ruby
  CONTRACT = ArchitectureAuditor::Contract
  W3_ROLE_KEY = CONTRACT::NODE_ROLE_KEY

  CLIENT_LIB = File.expand_path("../../lib", __dir__)

  # --- profile plumbing ---------------------------------------------------

  def shipped_document
    JSON.parse(JSON.generate(RUBY_NS::Profile::Profiles.load(RUBY_NS::Profile::DEFAULT_ID)))
  end

  # The rev-1.0 document, RECONSTRUCTED from rev 1.1 rather than re-typed.
  def role_stripped(node)
    case node
    when Hash  then node.each_with_object({}) { |(k, v), h| h[k] = role_stripped(v) unless k == "role" }
    when Array then node.map { |value| role_stripped(value) }
    else node
    end
  end

  def with_profile(document)
    allow(RUBY_NS::Profile).to receive(:for).and_return(RUBY_NS::Profile.new(document))
    yield
  end

  # --- capture plumbing ---------------------------------------------------

  def capture(corpus)
    Archbuddy::GoldenCorpus.capture(corpus)
  end

  # ONE reader, no rescue fallback: the harness hands back the exact bytes the
  # Serializer produced, so the Serializer's own string loader is the reader.
  # A rescue here would let a genuine parse failure masquerade as a successful
  # load through some other path.
  def graph_of(artifacts)
    CONTRACT::Serializer.load_string(artifacts.fetch("graph"))
  end

  # The captured graph bytes with every cco_role LINE removed. The serializer
  # emits one `key: value` per line, so dropping the key's lines is exactly
  # "un-append the new key" — no re-serialization, no normalisation that could
  # paper over a second difference.
  def without_role_lines(bytes)
    bytes.each_line.reject { |line| line.strip.start_with?("#{W3_ROLE_KEY}:") }.join
  end

  def counts(doc)
    { nodes: doc["nodes"].size, edges: doc["edges"].size, entrypoints: doc["entrypoints"].size }
  end

  # =====================================================================
  # QUESTION 1 — ZERO COUNT CHANGE, AND ONLY A KEY IS ADDED
  # =====================================================================
  describe "question 1: additive — a KEY, never a node" do
    Archbuddy::GoldenCorpus.corpora.each_key do |corpus|
      context "corpus #{corpus.inspect}" do
        it "node / edge / entrypoint counts are IDENTICAL with and without roles" do
          rev11 = graph_of(capture(corpus))
          rev10 = with_profile(role_stripped(shipped_document)) { graph_of(capture(corpus)) }

          expect(counts(rev11)).to eq(counts(rev10))
        end

        it "the ONLY byte-level delta is the appearance of cco_role keys" do
          rev11 = capture(corpus)
          rev10 = with_profile(role_stripped(shipped_document)) { capture(corpus) }

          rev11.each_key do |artifact|
            expect(without_role_lines(rev11.fetch(artifact))).to eq(rev10.fetch(artifact)),
                                                                 "#{corpus}.#{artifact} changed by something OTHER than the cco_role key"
          end
        end

        it "the role-free (rev 1.0) capture still emits a graph the ENGINE accepts" do
          # The cheap additive proof: an older, role-free profile keeps working
          # against this build, unchanged.
          rev10 = with_profile(role_stripped(shipped_document)) { graph_of(capture(corpus)) }

          expect(rev10["nodes"].none? { |n| n.key?(W3_ROLE_KEY) }).to be(true)
          expect(CONTRACT::Validator.valid?(:graph, rev10)).to be(true)
        end
      end
    end

    it "NON-VACUITY: at least one corpus actually stamps roles, on more than one value" do
      # Without this, every equality above could hold because NOTHING is ever
      # stamped and both arms are the same document.
      stamped = Archbuddy::GoldenCorpus.corpora.keys.flat_map do |corpus|
        graph_of(capture(corpus))["nodes"].filter_map { |n| n[W3_ROLE_KEY] }
      end

      expect(stamped.size).to be >= 5
      expect(stamped.uniq.size).to be >= 2
    end

    it "every stamped value is a member of the ENGINE schema's CLOSED enum" do
      enum = JSON.parse(File.read(CONTRACT::Validator.schema_path(:graph)))
                 .fetch("definitions").fetch("node").fetch("properties")
                 .fetch(W3_ROLE_KEY).fetch("enum")
      stamped = Archbuddy::GoldenCorpus.corpora.keys.flat_map do |corpus|
        graph_of(capture(corpus))["nodes"].filter_map { |n| n[W3_ROLE_KEY] }
      end

      expect(enum.sort).to eq(%w[action configuration no_io])
      expect((stamped.uniq - enum)).to eq([])
    end

    it "the role rides NEITHER back door: kind values and terminal_kind PRESENCE are bit-identical" do
      # The A6 exercise, hard-asserted over every node of every corpus. A6's two
      # doors both work by PRESENCE, so this compares the presence pattern, not
      # just the counts.
      Archbuddy::GoldenCorpus.corpora.each_key do |corpus|
        rev11 = graph_of(capture(corpus))
        rev10 = with_profile(role_stripped(shipped_document)) { graph_of(capture(corpus)) }

        expect(rev11["nodes"].map { |n| n["kind"] }).to eq(rev10["nodes"].map { |n| n["kind"] })
        expect(rev11["nodes"].map { |n| n.key?("terminal_kind") })
          .to eq(rev10["nodes"].map { |n| n.key?("terminal_kind") })
        expect(rev11["nodes"].map { |n| n["terminal_kind"] })
          .to eq(rev10["nodes"].map { |n| n["terminal_kind"] })
      end
    end
  end

  # =====================================================================
  # QUESTION 2 — THE TAG IS INERT (client half)
  # =====================================================================
  describe "question 2: inert — no client path reads it" do
    def code_only(source)
      source.each_line.reject { |line| line.strip.start_with?("#") }.join
    end

    def client_files(subdir)
      Dir[File.join(CLIENT_LIB, "archbuddy", subdir, "**", "*.rb")].sort
    end

    def files_containing(files, token)
      files.select { |path| code_only(File.read(path, encoding: "UTF-8")).include?(token) }
    end

    # Every client lane that computes, ranks or publishes a number.
    SCORING_LANES = %w[review report cache config cli].freeze

    it "VACUITY GUARD: the property name is well-formed and the scanned sets are non-empty" do
      expect(W3_ROLE_KEY).to match(/\A[a-z][a-z0-9_]*\z/)
      SCORING_LANES.each do |lane|
        expect(client_files(lane)).not_to be_empty, "no files scanned under lib/archbuddy/#{lane}"
      end
    end

    it "POSITIVE CONTROL: the same scan DOES find the property under collect/" do
      # The producer. Without this hit, every zero below could mean the scanner
      # reads nothing.
      hits = files_containing(client_files("collect"), W3_ROLE_KEY)

      expect(hits).not_to be_empty
      expect(hits.map { |p| File.basename(p) }).to include("anonymizer.rb")
    end

    it "no scoring, ranking or reporting lane references the property" do
      offenders = SCORING_LANES.flat_map { |lane| files_containing(client_files(lane), W3_ROLE_KEY) }

      expect(offenders).to be_empty,
                           "a client scoring path reads #{W3_ROLE_KEY.inspect}: " \
                           "#{offenders.map { |p| p.sub("#{CLIENT_LIB}/", '') }.inspect}"
    end

    it "the review lane's node model has no carrier for it — structural, not textual" do
      carriers = Archbuddy::Review::EpMetrics.members.map(&:to_s)

      expect(carriers).to include("entrypoint_kind") # positive control: real ones ARE here
      expect(carriers).not_to include(W3_ROLE_KEY)
    end
  end

  # =====================================================================
  # THE MUTATION — change a role value, confirm NO score moves
  # =====================================================================
  describe "the mutation: a changed role value moves no published number" do
    def findings_for(graph_doc)
      Tempfile.create(["graph", ".yml"]) do |graph_file|
        graph_file.write(CONTRACT::Serializer.dump(graph_doc))
        graph_file.flush
        out = Tempfile.new(["findings", ".yml"])
        out.close
        orig_out = $stdout
        orig_err = $stderr
        $stdout = StringIO.new
        $stderr = StringIO.new
        begin
          ArchitectureAuditor::CLI.call(arguments: ["analyze", graph_file.path, "--out", out.path])
        ensure
          $stdout = orig_out
          $stderr = orig_err
        end
        result = CONTRACT::Serializer.load(out.path)
        out.unlink
        return result
      end
    end

    # Rotate every stamped role onto a DIFFERENT member of the enum, read from
    # the schema. Rotation (not "set them all to X") guarantees every stamped
    # node actually changes value, whatever it started as.
    def rotated(doc)
      enum = JSON.parse(File.read(CONTRACT::Validator.schema_path(:graph)))
                 .fetch("definitions").fetch("node").fetch("properties")
                 .fetch(W3_ROLE_KEY).fetch("enum")
      copy = Marshal.load(Marshal.dump(doc))
      copy["nodes"].each do |node|
        next unless node.key?(W3_ROLE_KEY)

        node[W3_ROLE_KEY] = enum[(enum.index(node[W3_ROLE_KEY]) + 1) % enum.size]
      end
      copy
    end

    # A PURPOSE-BUILT fixture, not one of the golden corpora. Each golden
    # corpus exercises one vocabulary slice, so each is thin in a different
    # direction — measured: the ORM corpus mints ZERO terminal_kind sinks (so
    # `scores.egress` never populates) and the egress corpus has ZERO
    # entrypoints (so `findings` comes back empty). A byte-equality gate over a
    # findings document that is half-empty proves close to nothing, so this
    # fixture carries all three at once: entrypoints, roled db_ops, and roled +
    # unroled egress sinks. Every source below is SYNTHETIC and PUBLIC.
    W3_MUTATION_FILES = {
      "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
      "app/models/invoice.rb" => "class Invoice < ApplicationRecord\nend\n",
      "app/controllers/users_controller.rb" => <<~RUBY,
        class UsersController < ApplicationController
          def index
            User.where(active: true).pluck(:id)
            Reporter.new.summarize
          end

          def create
            User.create!(name: "x")
            Notifier.new.ping
          end

          def destroy
            User.destroy_all
            Invoice.update_all(seen: true)
          end
        end
      RUBY
      "app/controllers/invoices_controller.rb" => <<~RUBY,
        class InvoicesController < ApplicationController
          def show
            Invoice.find_by(id: 1)
            Reporter.new.summarize
          end
        end
      RUBY
      "app/services/reporter.rb" => <<~RUBY,
        class Reporter
          def summarize
            Invoice.count
            Invoice.new
            Faraday.get("/report")
            Excon.request(method: :get)
          end
        end
      RUBY
      "app/services/notifier.rb" => <<~RUBY
        class Notifier
          def ping
            HTTParty.post("/ping")
            Faraday.get("/ping")
            SomeGem.configure
          end
        end
      RUBY
    }.freeze

    let(:graph_doc) do
      Dir.mktmpdir("archbuddy-w3-mutation") do |dir|
        W3_MUTATION_FILES.each do |name, source|
          path = File.join(dir, name)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, source)
        end
        config = Archbuddy::Collect::Config.new(language: "ruby", probes: :all)
        raw    = Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
        Archbuddy::Collect::Anonymizer.new(raw, tool: "archbuddy w3", adapter: "ruby").call.graph
      end
    end

    it "NON-DEGENERACY: the fixture stamps roles AND produces a populated findings document" do
      stamped = graph_doc["nodes"].count { |n| n.key?(W3_ROLE_KEY) }
      expect(stamped).to be > 0
      expect(graph_doc["nodes"].size - stamped).to be > 0 # both arms, never single-armed

      findings = findings_for(graph_doc)
      expect(findings["findings"]).not_to be_empty
      expect(findings.dig("scores", "egress", "score")).to be_a(Numeric)
    end

    it "the ROTATION really changes the graph — the mutation can fire" do
      # The mutation battery's own precondition: a rotation that changed nothing
      # would make the invariance below vacuous.
      before = graph_doc["nodes"].filter_map { |n| n[W3_ROLE_KEY] }
      after  = rotated(graph_doc)["nodes"].filter_map { |n| n[W3_ROLE_KEY] }

      expect(before).not_to be_empty
      expect(after.size).to eq(before.size)
      expect(before.zip(after).all? { |b, a| b != a }).to be(true)
      expect(CONTRACT::Serializer.dump(rotated(graph_doc)))
        .not_to eq(CONTRACT::Serializer.dump(graph_doc))
    end

    it "…and the findings document is BYTE-IDENTICAL either way" do
      base    = CONTRACT::Serializer.dump(findings_for(graph_doc))
      mutated = CONTRACT::Serializer.dump(findings_for(rotated(graph_doc)))

      expect(mutated).to eq(base),
                         "rotating #{W3_ROLE_KEY} MOVED the findings — the role has become a scoring input"
    end

    it "REMOVING every role likewise moves nothing — presence is not a door either" do
      stripped = Marshal.load(Marshal.dump(graph_doc))
      stripped["nodes"].each { |node| node.delete(W3_ROLE_KEY) }

      expect(CONTRACT::Serializer.dump(findings_for(stripped)))
        .to eq(CONTRACT::Serializer.dump(findings_for(graph_doc)))
    end
  end
end
