# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# D-2 RATIFICATION GATE — THE THREE SCOPE SITES.
#
# `ResolutionPass` opens a fresh method scope at EXACTLY three places, and the
# usage pre-scan has to run at all three:
#
#   1. `visit_def_node`               — an ordinary `def`
#   2. the Grape verb-block branch    — `get "/x" do … end` has no DefNode
#   3. the Rake task-block branch     — `task :t do … end` has no DefNode
#
# A one-site (def-only) implementation is the plausible wrong reading, and it
# passes every fixture that only uses a plain class. So fixture (a) alone would
# be a FALSE-NEGATIVE GUARD; (b) and (c) are the mandatory ones. Dropping any
# single pre-scan call turns EXACTLY ONE of the three examples below red, and
# also makes `usage_unmapped` non-empty — two independent signals for one bug.
#
# WHY NON-`:unknown` FIXTURES. Each site asserts a SPECIFIC class, never merely
# "a usage is present". `:unknown` is what the walker produces when it has
# honestly nothing to say, so an assertion satisfied by `:unknown` would also be
# satisfied by a walker that classified nothing at all.
RSpec.describe "usage pre-scan covers all THREE method-scope sites (D-2)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  USAGE_SCOPE_HELPER = <<~RUBY
    class Helper
      def self.work
        1
      end

      def self.flag?
        true
      end
    end
  RUBY

  def in_repo(files)
    Dir.mktmpdir do |dir|
      files.each do |rel_path, content|
        abs = File.join(dir, rel_path)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, content)
      end
      yield dir
    end
  end

  def collect(dir)
    Archbuddy::Collect::Registry.for("ruby").new(dir, config).collect
  end

  # Re-run only the two passes so the raw Accumulator call records (which carry
  # the per-call-site usage) are inspectable — the adapter folds them into
  # edges and discards the records.
  def accumulator_for(dir)
    m     = Archbuddy::Collect::Adapters::Ruby
    table = m::SymbolTable.new
    files = m::FileEnumerator.new(dir, config).files.map { |abs, rel| [rel, Prism.parse(File.read(abs)).value] }
    files.each { |rel, parsed| parsed.accept(m::DefinitionPass.new(table, rel)) }

    acc    = m::Accumulator.new
    probes = m::ProbeRegistry.for(config)
    files.each do |rel, parsed|
      parsed.accept(m::ResolutionPass.new(table, acc, probes: probes, rel_file: rel))
    end
    acc
  end

  def usage_classes(acc, from_fq_fragment, to_fq)
    acc.calls.select { |c| c[:from_fq].to_s.include?(from_fq_fragment) && c[:to][:fq] == to_fq }
       .map { |c| c[:usage] }
  end

  describe "site 1 — an ordinary def" do
    it "classifies a call site inside a plain method body (non-:unknown)" do
      source = <<~RUBY
        class Caller
          def go
            Helper.work
            Helper.flag?
          end
        end
      RUBY
      in_repo("app/caller.rb" => source, "app/helper.rb" => USAGE_SCOPE_HELPER) do |dir|
        acc = accumulator_for(dir)
        # First statement is discarded => :effect. Non-:unknown, so a walker
        # that classified nothing cannot satisfy this.
        expect(usage_classes(acc, "Caller#go", "Helper.work")).to eq([:effect])
      end
    end
  end

  describe "site 2 — a Grape verb block (no DefNode exists)" do
    it "classifies a call site inside a handler block (non-:unknown)" do
      source = <<~RUBY
        class Api < Grape::API
          get "/x" do
            Helper.work
            Helper.flag?
          end
        end
      RUBY
      in_repo("app/api.rb" => source, "app/helper.rb" => USAGE_SCOPE_HELPER) do |dir|
        acc = accumulator_for(dir)
        expect(usage_classes(acc, "Api#GET", "Helper.work")).to eq([:effect])
      end
    end
  end

  describe "site 3 — a Rake task block (no DefNode exists)" do
    it "classifies a call site inside a task body (non-:unknown)" do
      in_repo("lib/tasks/t.rake" => "task :t do\n  Helper.work\n  Helper.flag?\nend\n",
              "app/helper.rb"    => USAGE_SCOPE_HELPER) do |dir|
        acc = accumulator_for(dir)
        expect(usage_classes(acc, "rake:t", "Helper.work")).to eq([:effect])
      end
    end
  end

  describe "the totality gate over all three sites at once" do
    it "leaves usage_unmapped EMPTY — never {walker_miss: 0}" do
      grape = <<~RUBY
        class Api < Grape::API
          get "/x" do
            Helper.work
          end
        end
      RUBY
      plain = <<~RUBY
        class Caller
          def go
            Helper.work
            Helper.flag?
          end
        end
      RUBY
      in_repo("app/api.rb"       => grape,
              "app/caller.rb"    => plain,
              "lib/tasks/t.rake" => "task :t do\n  Helper.work\nend\n",
              "app/helper.rb"    => USAGE_SCOPE_HELPER) do |dir|
        diagnostics = collect(dir).diagnostics
        expect(diagnostics[:usage_unmapped]).to eq({})
        # And the counters that DID fire are non-empty, so the empty result
        # above is a real zero rather than a pipeline that never ran.
        expect(diagnostics[:usage_counts]).not_to be_empty
      end
    end

    it "records a usage on EVERY call that became an edge, across the three sites" do
      grape = <<~RUBY
        class Api < Grape::API
          get "/x" do
            Helper.work
          end
        end
      RUBY
      plain = <<~RUBY
        class Caller
          def go
            Helper.work
          end
        end
      RUBY
      in_repo("app/api.rb"       => grape,
              "app/caller.rb"    => plain,
              "lib/tasks/t.rake" => "task :t do\n  Helper.work\nend\n",
              "app/helper.rb"    => USAGE_SCOPE_HELPER) do |dir|
        acc = accumulator_for(dir)
        recorded = acc.calls.reject { |c| c[:usage].nil? }
        expect(recorded.size).to eq(acc.calls.size)
        expect(acc.calls.size).to be >= 3
      end
    end
  end

  describe "the degenerate case" do
    it "tallies nothing for a file with no def, verb or task" do
      in_repo("app/constants.rb" => "CONSTANT = [1, 2, 3].freeze\n") do |dir|
        expect(collect(dir).diagnostics[:usage_unmapped]).to eq({})
      end
    end
  end
end
