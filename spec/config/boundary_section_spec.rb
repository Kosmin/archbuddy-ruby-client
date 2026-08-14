# frozen_string_literal: true

require "json"
require "tmpdir"
require "archbuddy/config"

# configurator W4 (C10) — `.archbuddy.yml` gains exactly ONE key: `boundary:`.
#
# The whole point of the task is WHERE the rejection comes from. A project must
# not be able to invent boundary grammar the engine's profile does not have, and
# the way that is guaranteed is that this repo never describes the grammar at
# all: the section is wrapped in a schema-derived profile envelope and handed to
# the engine's `Contract::Validator`. So most of this file is about proving the
# PROVENANCE of an error, not merely that an error occurs.
RSpec.describe Archbuddy::Config::BoundarySection do
  Contract = ArchitectureAuditor::Contract

  # The producer. Every claim below about what the boundary grammar permits is
  # read from HERE, never re-typed from the prose.
  def profile_schema
    @profile_schema ||= JSON.parse(File.read(Contract::Validator.schema_path(:profile)))
  end

  def boundary_definition(name)
    profile_schema.fetch("definitions").fetch(name)
  end

  def errors_for(section)
    described_class.errors(section)
  end

  # End-to-end through the real loader, so the delegation in Config::Validator
  # is exercised and not just this class in isolation.
  def config_errors(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml)
      Archbuddy::Config.load(target_root: dir)
      return []
    end
  rescue Archbuddy::Config::ValidationError => e
    e.message.split("\n")
  end

  # A section exercising ALL THREE granularities at once, so nothing below is
  # measured on a degenerate one-rule document.
  def full_section
    {
      "paths"   => [{ "glob" => "vendor/**/*.rb", "category" => "gem" }],
      "classes" => [{ "kind" => "ancestor_of", "values" => %w[Vendor::Base] , "category" => "gem" }],
      "calls"   => [{ "receiver" => { "kind" => "constant_exact", "values" => %w[Payments::Gateway] },
                      "verbs" => %w[charge], "category" => "http", "role" => "action" }]
    }
  end

  # --- non-degeneracy, asserted BEFORE anything is measured on it -----------

  describe "the fixture is not degenerate" do
    it "declares every granularity the producer defines" do
      declared = boundary_definition("boundary").fetch("properties").keys
      expect(declared).to match_array(%w[paths classes calls])
      expect(full_section.keys).to match_array(declared)
    end

    it "validates clean, so every rejection below is about the mutation and not the fixture" do
      expect(errors_for(full_section)).to eq([])
    end
  end

  # --- the absent / empty states stay distinguishable -----------------------

  describe "absence" do
    it "reports nothing when the key is absent (an override is opt-in)" do
      expect(errors_for(nil)).to eq([])
    end

    it "accepts a present-but-empty section (a different state from absent, not an error)" do
      expect(errors_for({})).to eq([])
    end

    it "leaves a config with no boundary key entirely unaffected" do
      expect(config_errors("version: 1\n")).to eq([])
    end
  end

  # --- THE ACCEPTANCE ANCHOR ------------------------------------------------
  #
  # The rejection must come from the schema's own additionalProperties, NOT from
  # Config::Validator#check_unknown_keys. Three independent proofs, because any
  # one of them alone could be satisfied by an accident.

  describe "the rejection comes from JSON-Schema additionalProperties" do
    let(:unknown_key_section) { full_section.merge("subtrees" => []) }

    it "1/3 — carries the schema's additionalProperties wording, naming the offending key" do
      expect(errors_for(unknown_key_section)).to contain_exactly(
        a_string_including("contains additional properties [\"subtrees\"] outside of the schema")
      )
    end

    it "2/3 — is NOT spelled the way check_unknown_keys spells its errors" do
      # `Config::Validator#unknown_key` emits "unknown key 'x' at <path>".
      # A boundary rejection can never read like that, because this repo holds
      # no list of boundary key names to compare against.
      errors = config_errors("version: 1\nboundary:\n  subtrees: []\n")
      expect(errors).not_to be_empty
      expect(errors).to all(satisfy { |e| !e.start_with?("unknown key ") })
      expect(errors.join).to include("additional properties")
    end

    it "3/3 — the key is REGISTERED top-level, so the generic unknown-key check passes it through" do
      # Were `boundary` missing from TOP_LEVEL_KEYS, the generic check would
      # claim it first and the schema would never see the document at all.
      expect(Archbuddy::Config::Schema::TOP_LEVEL_KEYS).to include(described_class::KEY)
      expect(config_errors("version: 1\nboundary: {}\n")).to eq([])
    end

    it "names the offending key by its .archbuddy.yml path, indices included" do
      section = { "classes" => [{ "kind" => "constant_exact", "values" => %w[A] },
                                { "kind" => "constant_exact", "values" => %w[B], "nope" => 1 }] }
      expect(errors_for(section)).to contain_exactly(
        a_string_including("'boundary.classes[1]'")
      )
    end

    it "drops the engine's schema URI from the user-facing message" do
      expect(errors_for(full_section.merge("subtrees" => [])).join).not_to include("in schema")
    end
  end

  # --- the role restriction is INHERITED, not re-asserted -------------------

  describe "role is permitted on a call rule ONLY, structurally" do
    it "the producer says so: `role` is in the call rule's properties and no other's" do
      expect(boundary_definition("boundary_call_rule").fetch("properties")).to have_key("role")
      expect(boundary_definition("boundary_class_rule").fetch("properties")).not_to have_key("role")
      expect(boundary_definition("boundary_path_rule").fetch("properties")).not_to have_key("role")
    end

    it "accepts role on a call rule" do
      expect(errors_for("calls" => [full_section["calls"].first])).to eq([])
    end

    %w[classes paths].each do |granularity|
      it "rejects role on a #{granularity} rule via additionalProperties, not a hand-written check" do
        rule    = full_section.fetch(granularity).first.merge("role" => "action")
        errors  = errors_for(granularity => [rule])
        expect(errors).to contain_exactly(
          a_string_including("'boundary.#{granularity}[0]'")
            .and(a_string_including("additional properties [\"role\"]"))
        )
      end
    end

    it "rejects a role OUTSIDE the producer's enum" do
      rule = full_section["calls"].first.merge("role" => "control")
      # `control` is a CCO layer that by definition crosses no boundary — the
      # producer excludes it deliberately. Read the enum from the producer.
      expect(profile_schema.dig("definitions", "role", "enum")).not_to include("control")
      expect(errors_for("calls" => [rule])).to contain_exactly(
        a_string_including("'boundary.calls[0].role'")
      )
    end
  end

  # --- a project cannot invent a matcher kind ------------------------------

  describe "constant match kinds come from the producer's closed enum" do
    it "rejects an AST-shaped matcher kind, so the middleware hazard stays inexpressible" do
      enum = boundary_definition("constant_match_kind").fetch("enum")
      expect(enum).to match_array(%w[constant_exact constant_prefix ancestor_of])
      expect(enum.grep(/shape|arity|ivar|param/)).to be_empty

      errors = errors_for("classes" => [{ "kind" => "method_shape", "values" => %w[A] }])
      expect(errors).to contain_exactly(a_string_including("'boundary.classes[0].kind'"))
    end
  end

  # --- the honest gap: category is NOT closed by the schema -----------------

  describe "category" do
    it "is UNCONSTRAINED by the schema, by the producer's own declaration" do
      # Stated here rather than smoothed over: the config surface will accept
      # an out-of-vocabulary category. The closed gate is BoundaryRules'
      # load-time UnknownCategoryError, which reads Contract::TERMINAL_KINDS.
      expect(boundary_definition("crossing_category")).not_to have_key("enum")
      expect(errors_for("paths" => [{ "glob" => "x/**", "category" => "database" }])).to eq([])
    end

    it "is closed at LOAD by the one producer, which this surface defers to" do
      expect(Contract::TERMINAL_KINDS).not_to include("database")
      expect do
        Archbuddy::Collect::Adapters::Ruby::BoundaryRules.new(
          "paths" => [{ "glob" => "x/**", "category" => "database" }]
        )
      end.to raise_error(
        Archbuddy::Collect::Adapters::Ruby::BoundaryRules::UnknownCategoryError,
        /database/
      )
    end
  end

  # --- L17: same-root multi-instance, refused LOUDLY ------------------------

  describe "L17 — a sequence of boundaries at one root is refused" do
    let(:sequence) { [full_section, full_section] }

    it "fails with a message naming the supported shape" do
      errors = errors_for(sequence)
      expect(errors).to contain_exactly(described_class::MULTI_INSTANCE_ERROR)
      expect(errors.first).to include("single mapping")
      expect(errors.first).to include("run archbuddy separately at each component root")
    end

    it "fails through the real loader too, not just this class" do
      yaml = "version: 1\nboundary:\n  - paths: []\n  - paths: []\n"
      expect(config_errors(yaml)).to contain_exactly(described_class::MULTI_INSTANCE_ERROR)
    end

    it "is about the SHAPE and not the content — the same content as ONE mapping is clean" do
      expect(errors_for(sequence.first)).to eq([])
    end

    it "does not preempt additionalProperties: a mapping with an unfamiliar key still" \
       " gets the schema's rejection" do
      expect(errors_for("subtrees" => [])).to contain_exactly(
        a_string_including("additional properties")
      )
    end

    it "reports the refusal INSTEAD of a bare type error, which names no shape" do
      expect(errors_for(sequence).join).not_to include("did not match the following type")
    end
  end

  # --- the envelope is derived from the producer, and its guard can fire ----

  describe "the envelope" do
    it "satisfies every key the producer marks required, without re-typing the list" do
      envelope = described_class.send(:envelope, full_section)
      expect(profile_schema.fetch("required")).not_to be_empty
      expect(envelope.keys).to include(*profile_schema.fetch("required"))
      expect(Contract::Validator.valid?(:profile, envelope)).to be(true)
    end

    it "carries the version from its producing constant, not a literal" do
      envelope = described_class.send(:envelope, {})
      expect(envelope["profile_schema_version"]).to eq(Contract::PROFILE_SCHEMA_VERSION)
    end

    it "LOUD-SKIPS: a fault outside #/boundary raises rather than being filtered away" do
      # A guard that cannot fire guards nothing. This is the permanent control
      # that the envelope-bug path is real: an engine message pointing anywhere
      # but #/boundary must never be silently dropped as "not the project's".
      expect do
        described_class.send(:rewrite, "The property '#/framework' of type array did not match")
      end.to raise_error(described_class::EnvelopeError, %r{#/boundary})
    end

    it "does not fault on a message that IS about the boundary" do
      expect(
        described_class.send(:rewrite, "The property '#/boundary/paths/0' is bad in schema x")
      ).to eq("The property 'boundary.paths[0]' is bad")
    end
  end

  # --- the key changes nothing else about the config ------------------------

  describe "blast radius" do
    it "does not alter rule resolution, gating or severities" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".archbuddy.yml"), "version: 1\n")
        without = Archbuddy::Config.load(target_root: dir)
        File.write(File.join(dir, ".archbuddy.yml"),
                   "version: 1\nboundary:\n  paths:\n    - glob: 'vendor/**'\n")
        with = Archbuddy::Config.load(target_root: dir)

        expect(with.enabled_rules).to eq(without.enabled_rules)
        expect(with.effective_fail_level).to eq(without.effective_fail_level)
        expect(with.rule_for("UseCaseComplexity", file: nil).to_h)
          .to eq(without.rule_for("UseCaseComplexity", file: nil).to_h)
      end
    end
  end
end
