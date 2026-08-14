# frozen_string_literal: true

require "fileutils"
require "prism"
require "stringio"
require "tmpdir"
require "yaml"
require "archbuddy/cli/collect"
require "archbuddy/collect"

# configurator W4 (C13) — the receiver-shape HOIST + `receiver_shape_counts`.
#
# The hoist is a PURE DE-DUPLICATION and the counts are a DIAGNOSTIC. Neither
# may move a score, so most of this file is about the things a careless version
# of either would break: the six call sites do not agree with one another, and
# an over-eager "one shared receiver_fq" would silently change four of them.
# NOTE (learned the hard way in C11): a constant assigned inside an
# `RSpec.describe` block binds at TOP-LEVEL lexical scope, i.e. on Object. Every
# shared value in this file is therefore a METHOD.
RSpec.describe Archbuddy::Collect::Adapters::Ruby::ReceiverShape do
  def ruby_ns
    Archbuddy::Collect::Adapters::Ruby
  end

  # The receiver of the LAST statement, so a fixture may declare a local first.
  # `x.foo` with no prior `x = …` parses as a CHAIN of two method calls, not a
  # local-variable read — Prism decides that from the assignment, not the name.
  def parse_receiver(source)
    Prism.parse(source).value.statements.body.last.receiver
  end

  # --- the shape vocabulary -------------------------------------------------

  describe ".of" do
    {
      "foo"            => :self,
      "self.foo"       => :self,
      "Const.foo"      => :literal_const,
      "Const::Path.foo" => :literal_const,
      "x = 1\nx.foo"   => :local,
      "x.foo"          => :chained, # NO prior assignment => a method call, not a local
      "@x.foo"         => :ivar,
      "a.b.foo"        => :chained,
      "Const.new.foo"  => :chained,
      "'str'.foo"      => :other,
      "[1].foo"        => :other
    }.each do |source, shape|
      it "classifies `#{source}` as :#{shape}" do
        expect(described_class.of(parse_receiver(source))).to eq(shape)
      end
    end

    it "never returns a shape outside its own closed vocabulary" do
      sources = ["foo", "self.foo", "Const.foo", "x = 1\nx.foo", "@x.foo", "a.b.foo", "'s'.foo",
                 "1.foo", ":sym.foo", "nil.foo", "$g.foo", "@@c.foo", "CONST_X.foo"]
      shapes = sources.map { |src| described_class.of(parse_receiver(src)) }
      expect(shapes.uniq - described_class::SHAPES).to be_empty
      # Non-degeneracy: the sample really does span more than one bucket.
      expect(shapes.uniq.size).to be >= 4
    end
  end

  describe "the primitives decline rather than guess" do
    it "constant_fq is literal-constants-only" do
      expect(described_class.constant_fq(parse_receiver("Const::Path.foo"))).to eq("Const::Path")
      expect(described_class.constant_fq(parse_receiver("x = 1\nx.foo"))).to be_nil
      expect(described_class.constant_fq(parse_receiver("Const.new.foo"))).to be_nil
    end

    it "constructor_chain? is `.new` with a receiver, and nothing else" do
      expect(described_class.constructor_chain?(parse_receiver("Const.new.foo"))).to be(true)
      expect(described_class.constructor_chain?(parse_receiver("Const.build.foo"))).to be(false)
      expect(described_class.constructor_chain?(parse_receiver("new.foo"))).to be(false)
      expect(described_class.constructor_constant_fq(parse_receiver("Const.new.foo"))).to eq("Const")
      expect(described_class.constructor_constant_fq(parse_receiver("x = 1\nx.new.foo"))).to be_nil
    end

    it "scope_key covers local / ivar / BARE accessor call, and declines a real chain" do
      expect(described_class.scope_key(parse_receiver("x = 1\nx.foo"))).to eq("x")
      expect(described_class.scope_key(parse_receiver("@x.foo"))).to eq("@x")
      expect(described_class.scope_key(parse_receiver("svc.foo"))).to eq("svc")
      expect(described_class.scope_key(parse_receiver("a.b.foo"))).to be_nil
      expect(described_class.scope_key(parse_receiver("Const.foo"))).to be_nil
    end
  end

  # --- the hoist actually removed the duplicates ----------------------------

  describe "the hoist is complete (a drift lock, not a comment)" do
    def hoisted
      %w[
        resolver.rb
        resolution_pass.rb
        boundary_rules.rb
        probes/meta_send_probe.rb
        probes/egress_probe.rb
        probes/dispatch_probe.rb
      ]
    end

    def source_of(rel)
      File.read(File.expand_path("../../lib/archbuddy/collect/adapters/ruby/#{rel}", __dir__))
    end

    it "leaves NO consumer holding its own constant-node ladder — with a positive control" do
      # The 0-hit is only meaningful if the pattern can match: it does, in the
      # one place the ladder now lives.
      expect(source_of("receiver_shape.rb")).to include("Prism::ConstantReadNode")

      hoisted.each do |rel|
        code = source_of(rel).lines.reject { |line| line.strip.start_with?("#") }.join
        expect(code).not_to include("Prism::ConstantReadNode"),
                            "#{rel} still spells the constant ladder itself"
      end
    end

    it "every hoisted file reaches the module it was hoisted into" do
      hoisted.each do |rel|
        expect(source_of(rel)).to include("ReceiverShape"), "#{rel} does not use the hoist"
      end
    end
  end

  # --- THE DISAGREEMENTS the hoist had to preserve --------------------------
  #
  # These are the four behaviours a single shared `receiver_fq` would have
  # erased. Each is asserted at the level of the emitted graph, not by reading
  # the method.

  describe "the six call sites still disagree, exactly as they did before" do
    # NO keyword parameters here on purpose: a brace-less hash argument would be
    # taken as keywords in Ruby 3 and the call would arrive with zero args.
    def collect(files)
      Dir.mktmpdir("archbuddy-c13") do |dir|
        files.each do |rel, src|
          abs = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(abs))
          File.write(abs, src)
        end
        config = Archbuddy::Collect::Config.new(language: "ruby", entrypoint_strategy: :all_public)
        return Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
      end
    end

    def edges_of(result)
      by_key = result.nodes.to_h { |n| [n.real_key, n.symbol] }
      result.edges.map { |e| [by_key[e.from_key], by_key[e.to_key]] }
    end

    it "MetaSendProbe resolves a SELF receiver (R4.5 does not, and must not)" do
      result = collect(
        "app/x.rb" => <<~RUBY
          class Holder
            def outer
              send(:inner)
            end

            def inner
              1
            end
          end
        RUBY
      )
      expect(edges_of(result)).to include(%w[Holder#outer Holder#inner])
    end

    # THE SHARP ONE. A BARE memoized-accessor receiver is the case where R4.5 and
    # MetaSendProbe genuinely disagree AND the scope lookup would succeed: R4.5
    # resolves `svc.work`, but `svc.send(:work)` must still DECLINE, because the
    # probe never learned :chained. Measured, not assumed — the first version of
    # this example used `Target.new.send(:inner)`, whose scope_key is nil, so it
    # passed even with :chained wired into the probe. It caught nothing.
    it "MetaSendProbe DECLINES a chained receiver even when the type scope knows it" do
      files = {
        "app/x.rb" => <<~RUBY
          class Svc
            def work
              1
            end
          end

          class Holder
            def direct
              svc.work
            end

            def meta
              svc.send(:work)
            end

            def svc
              @svc ||= Svc.new
            end
          end
        RUBY
      }
      edges = edges_of(collect(files))

      # NON-DEGENERACY: the very same receiver IS resolvable — R4.5 resolves it.
      expect(edges).to include(%w[Holder#direct Svc#work])
      # …and the meta-dispatch site still does not.
      expect(edges).not_to include(%w[Holder#meta Svc#work])
    end

    it "MetaSendProbe also declines an inline `Const.new` meta-dispatch" do
      result = collect(
        "app/x.rb" => <<~RUBY
          class Target
            def inner
              1
            end
          end

          class Holder
            def outer
              Target.new.send(:inner)
            end
          end
        RUBY
      )
      expect(edges_of(result)).not_to include(%w[Holder#outer Target#inner])
    end

    it "R4.5 resolves a BARE memoized-accessor receiver (MetaSendProbe would not)" do
      result = collect(
        "app/x.rb" => <<~RUBY
          class Svc
            def work
              1
            end
          end

          class Holder
            def outer
              svc.work
            end

            def svc
              @svc ||= Svc.new
            end
          end
        RUBY
      )
      expect(edges_of(result)).to include(%w[Holder#outer Svc#work])
    end

    it "BoundaryRules never claims a SELF receiver — a boundary is crossed, not inhabited" do
      section = { "classes" => [{ "kind" => "constant_exact", "values" => %w[Holder],
                                  "category" => "gem" }] }
      profile = ruby_ns::Profile.for(nil, boundary_override: section)
      begin
        result = Dir.mktmpdir("archbuddy-c13-bd") do |dir|
          File.write(File.join(dir, "x.rb"), <<~RUBY)
            class Holder
              def outer
                inner
              end

              def inner
                1
              end
            end
          RUBY
          config = Archbuddy::Collect::Config.new(language: "ruby", entrypoint_strategy: :all_public,
                                                  boundary_override: section)
          Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
        end
        # NON-DEGENERACY: the rule is live — it names a class that exists, and
        # the merge really put it in force (the shipped granularities survive
        # alongside it, which is the C11 merge doctrine).
        expect(profile.boundary["classes"]).to eq(section["classes"])
        # …and the self-call is STILL a real in-tree edge, not a crossing.
        expect(edges_of(result)).to include(%w[Holder#outer Holder#inner])
      ensure
        ruby_ns::Profile.reset_memo!
      end
    end

    it "DispatchProbe still unwraps exactly ONE `.set` hop and no deeper chain" do
      result = collect(
        {
          "app/jobs/report_job.rb" => <<~RUBY,
            class ReportJob < ApplicationJob
              def perform
                1
              end
            end
          RUBY
          "app/services/enq.rb" => <<~RUBY
            class Enq
              def one
                ReportJob.set(wait: 5).perform_later
              end

              def two
                ReportJob.set(wait: 5).set(wait: 6).perform_later
              end
            end
          RUBY
        }
      )
      edges = edges_of(result)
      expect(edges).to include(%w[Enq#one ReportJob#perform])
      expect(edges).not_to include(%w[Enq#two ReportJob#perform])
    end
  end
end

# --- the diagnostic ---------------------------------------------------------

RSpec.describe Archbuddy::Collect::Adapters::Ruby::ReceiverShapeTally do
  def ruby_ns
    Archbuddy::Collect::Adapters::Ruby
  end

  # ONE unresolved call site per shape, plus one RESOLVED site so the tally is
  # shown to be selective rather than merely counting everything.
  #
  # Shape notes, each chosen deliberately:
  #   :literal_const — must name an IN-TREE constant. An out-of-tree literal
  #     constant is claimed by the EgressProbe's `:gem` catch-all and is
  #     therefore RESOLVED, never an R9 fallthrough.
  #   :ivar          — CONSTRUCTOR-INJECTED, which is the honest cap this
  #     counter documents: the widening could never recover it.
  #
  # MEASURED, NOT ASSUMED: `Widget.new` is ITSELF a call site (receiver `Widget`,
  # verb `new`), and `new` is not a captured method on an in-tree class — so the
  # :literal_const bucket reads 2, not 1. That is the honest count and it is
  # pinned as such rather than filtered: a tally that quietly dropped
  # constructor calls would under-report the very idiom the deferred widening
  # targets.
  def unresolved_corpus
    {
      "app/widget.rb" => <<~RUBY,
        class Widget
        end
      RUBY
      "app/probe.rb" => <<~RUBY
        class Probe
          def initialize(client)
            @client = client
          end

          def run(arg)
            frobnicate_bare
            Widget.frobnicate_const
            arg.frobnicate_local
            @client.frobnicate_ivar
            Widget.new.frobnicate_chained
            "s".frobnicate_other
            helper
          end

          def helper
            1
          end
        end
      RUBY
    }
  end

  def diagnostics_for(files)
    Dir.mktmpdir("archbuddy-c13-tally") do |dir|
      files.each do |rel, src|
        abs = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, src)
      end
      config = Archbuddy::Collect::Config.new(language: "ruby", entrypoint_strategy: :all_public)
      return Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect.diagnostics
    end
  end

  describe "receiver_shape_counts" do
    subject(:counts) { diagnostics_for(unresolved_corpus)[:receiver_shape_counts] }

    it "NON-DEGENERACY: it spans every shape in the closed vocabulary at once" do
      expect(counts.keys).to match_array(ruby_ns::ReceiverShape::SHAPES)
    end

    it "counts EXACTLY the unresolved sites, per shape" do
      expect(counts).to eq(
        self: 1, literal_const: 2, local: 1, ivar: 1, chained: 1, other: 1
      )
    end

    it "does NOT count a resolved site — `helper` is a real edge in the same method" do
      # Two-sided, and pinned on both sides: `run` holds EIGHT call sites, of
      # which exactly one (`helper`) resolves. A tally that counted every site
      # would read 8; one that counted none would read 0.
      expect(counts.values.sum).to eq(7)
      expect(diagnostics_for(unresolved_corpus)[:total_call_sites]).to eq(8)
    end

    it "leaves a shape that never occurred ABSENT rather than a fabricated zero" do
      counts = diagnostics_for(
        "app/x.rb" => <<~RUBY
          class Only
            def run
              nope_bare
            end
          end
        RUBY
      )[:receiver_shape_counts]
      expect(counts).to eq(self: 1)
      expect(counts).not_to have_key(:literal_const)
    end

    it "is {} — not a row of zeros — when nothing went unresolved" do
      counts = diagnostics_for(
        "app/x.rb" => <<~RUBY
          class Clean
            def run
              helper
            end

            def helper
              1
            end
          end
        RUBY
      )[:receiver_shape_counts]
      expect(counts).to eq({})
    end

    it "reads its predicate from the PRODUCER, not a re-typed symbol" do
      expect(ruby_ns::RubyResolver::UNRESOLVED_TIER).to eq(:external)
      source = File.read(
        File.expand_path("../../lib/archbuddy/collect/adapters/ruby/receiver_shape_tally.rb", __dir__)
      )
      expect(source).to include("RubyResolver::UNRESOLVED_TIER")
    end
  end

  # --- it measures, it does not widen --------------------------------------

  describe "NO literal-receiver widening ships with the count" do
    # ONE corpus pair, differing only in whether the chained verb is known. The
    # :literal_const entry (the `Target.new` site itself) is IDENTICAL in both,
    # which is what isolates the claim to the chained site.
    it "an inline `Const.new` chain whose target IS known still resolves (unchanged)" do
      diagnostics = diagnostics_for(
        "app/x.rb" => <<~RUBY
          class Target
            def known
              1
            end
          end

          class Holder
            def run
              Target.new.known
            end
          end
        RUBY
      )
      expect(diagnostics[:receiver_shape_counts]).to eq(literal_const: 1)
    end

    it "an inline `Const.new` chain whose target is UNKNOWN is COUNTED, not claimed" do
      diagnostics = diagnostics_for(
        "app/x.rb" => <<~RUBY
          class Target
          end

          class Holder
            def run
              Target.new.unknown
            end
          end
        RUBY
      )
      # Counted as :chained — and still an <external> fallthrough, i.e. observed
      # rather than recovered. The widening that WOULD recover it is deferred.
      expect(diagnostics[:receiver_shape_counts]).to eq(literal_const: 1, chained: 1)
      expect(diagnostics[:egress_counts][:generic]).to eq(2)
    end
  end

  # --- diagnostics only -----------------------------------------------------

  describe "the tally never becomes content" do
    def run_cli(files)
      Dir.mktmpdir("archbuddy-c13-cli") do |dir|
        files.each do |rel, src|
          abs = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(abs))
          File.write(abs, src)
        end
        out_dir = File.join(dir, "out")
        stderr  = StringIO.new
        orig    = $stderr
        $stderr = stderr
        begin
          Archbuddy::CLI::Collect.new.call(path: dir, out_dir: out_dir, language: "ruby",
                                           entrypoints: "all_public", entrypoint_pattern: [])
        ensure
          $stderr = orig
        end
        return { stderr: stderr.string,
                 graph: File.read(File.join(out_dir, "graph.yml")),
                 id_map: File.read(File.join(out_dir, "id-map.yml")) }
      end
    end

    it "prints the breakdown on stderr and puts NONE of it in graph.yml or id-map.yml" do
      result = run_cli(unresolved_corpus)

      expect(result[:stderr]).to include(
        "note: 7 unresolved call sites by receiver shape " \
        "(chained=1 ivar=1 literal_const=2 local=1 other=1 self=1)"
      )

      [result[:graph], result[:id_map]].each do |content|
        expect(content).not_to include("receiver_shape")
        expect(content).not_to include("unresolved call site")
      end
    end

    it "stays SILENT on a fully-resolved run rather than printing zeros" do
      result = run_cli(
        "app/x.rb" => <<~RUBY
          class Clean
            def run
              helper
            end

            def helper
              1
            end
          end
        RUBY
      )
      expect(result[:stderr]).not_to include("by receiver shape")
    end
  end
end
