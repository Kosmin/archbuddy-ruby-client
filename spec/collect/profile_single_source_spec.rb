# frozen_string_literal: true

require "spec_helper"

# THE SINGLE-SOURCE GATE (configurator W2).
#
# The purity gate next door proves the migration did not CHANGE anything. This
# one proves it actually MOVED something: that the vocabulary now lives in the
# engine-shipped profile and nowhere else. Without it, a migration that reads
# the profile while quietly retaining the old constants would pass the golden
# and leave two sources of truth to drift apart.
#
# Nothing here re-types canon. Every value is read from the shipped profile (or
# from the shipped source); the assertions are about WHERE those values live.
RSpec.describe "profile single-source" do
  R       = Archbuddy::Collect::Adapters::Ruby
  profile = R::Profile.reference

  # Comment-stripped Ruby source of the whole library, with `%w[...]` word
  # arrays expanded into quoted strings.
  #
  # Comments are excluded deliberately: prose that NAMES a moved constant is
  # documentation of the move (and several files carry exactly that), not a
  # second source of truth. `%w` is expanded because every list the migration
  # deleted was written as a `%w` literal — scanning only for quoted strings
  # would miss the exact shape a resurrection would take.
  lib_sources = Dir.glob(File.expand_path("../../lib/**/*.rb", __dir__)).to_h do |path|
    stripped = File.readlines(path).reject { |line| line.lstrip.start_with?("#") }.join
    expanded = stripped.gsub(/%[wi]\[(.*?)\]/m) { Regexp.last_match(1).split.map(&:inspect).join(" ") }
    [path.sub(%r{\A.*/lib/}, "lib/"), expanded]
  end

  hits = lambda do |pattern|
    lib_sources.filter_map { |file, src| file if src.match?(pattern) }
  end

  # The constants the migration deleted. Their absence is the migration.
  MIGRATED_CONSTANTS = %w[
    OPERATOR_DENY METAPROGRAMMING META_RESOLVABLE
    ACTIVE_RECORD ACTIVE_RECORD_BASES CONTROLLER_BASES
    EGRESS_HTTP_CONSTANTS EGRESS_HTTP_VERBS
    SIDEKIQ_WORKER_MIXINS SIDEKIQ_WORKER_BASES ACTIVE_JOB_BASES
    DISPATCH_METHODS SCRIPT_DIRS LOADER_CALLS
    SIDEKIQ_CRON_PATHS WHENEVER_PATH PERFORM_FAMILY
    CATEGORY_PRECEDENCE SEEDED_CATEGORIES
  ].freeze

  # POSITIVE CONTROL for every absence assertion below. These constants are
  # still in `lib/` on purpose — the pure Prism-shape recognizers (GrapeDsl,
  # MixinDsl, RackMiddleware) hold no symbol table, so they are NOT on the
  # `SymbolTable#profile` seam and their vocabulary did not move in W2. If the
  # scanner below ever stops finding THEM, its zero-hit results mean nothing.
  SURVIVING_CONSTANTS = %w[HTTP_VERBS GRAPE_API_BASES MIXIN_METHODS REGISTRATION_METHODS].freeze

  describe "the migrated constants are gone from lib/" do
    SURVIVING_CONSTANTS.each do |name|
      it "positive control: still finds #{name}" do
        expect(hits.call(/\b#{name}\b/)).not_to be_empty
      end
    end

    MIGRATED_CONSTANTS.each do |name|
      it "#{name} is defined nowhere in lib/" do
        expect(hits.call(/\b#{name}\b/)).to be_empty
      end
    end

    it "leaves Vocab with exactly one public predicate — the AST-shape one" do
      expect(R::Vocab.singleton_methods(false).sort).to eq(%i[literal_dispatch_arg?])
    end
  end

  # WHICH DOCUMENT PATHS W2 ACTUALLY MOVED. The profile ships more vocabulary
  # than this wave consumes, so "every migrated literal is absent from lib/" is
  # only meaningful against an explicit list — and the two lists below must
  # TOGETHER cover the whole document, or a future profile artifact could be
  # added and silently escape this gate.
  MIGRATED_PATHS = [
    %w[language operator_deny],
    %w[language dynamic_dispatch_verbs],
    %w[language resolvable_dispatch_verbs],
    %w[framework orm methods],
    %w[framework orm base_classes],
    %w[framework controllers base_classes],
    %w[framework controllers name_suffixes],
    %w[framework jobs mixins],
    %w[framework jobs base_classes],
    %w[framework jobs dispatch_verbs],
    %w[framework entrypoints seeded_categories],
    %w[framework scripts dirs],
    %w[framework scripts loader_only_calls],
    %w[framework cron config_paths],
    %w[framework cron whenever_path],
    %w[framework cron runner_target_verbs],
    %w[library egress]
  ].freeze

  # NOT moved in W2, each for a stated reason — every one of these is a place
  # the vocabulary is STILL hardcoded in lib/, on purpose.
  NOT_MIGRATED_PATHS = {
    %w[language mixin_verbs]                     => "MixinDsl: a pure Prism recognizer, no symbol table in scope",
    %w[framework grape endpoint_verbs]           => "GrapeDsl: same — pure recognizer, off the SymbolTable#profile seam",
    %w[framework grape api_base_classes]         => "GrapeDsl, and ClassEntry#grape_api? which has no profile",
    %w[framework middleware registration_verbs]  => "RackMiddleware: same pure-recognizer family",
    %w[framework entrypoints category_precedence] => "the categories are #category_for's RETURN values; the " \
                                                    "profile lists them as the declaration of that order",
    %w[framework orm lazy_methods]               => "declared empty; no client consumer yet",
    %w[boundary paths]                           => "the boundary primitive is a later wave",
    %w[boundary classes]                         => "the boundary primitive is a later wave",
    %w[boundary calls]                           => "the boundary primitive is a later wave"
  }.freeze

  # Document-level metadata, not vocabulary.
  METADATA_KEYS = %w[profile_schema_version profile_id title].freeze

  describe "the migrated VALUES are gone from lib/" do
    document = R::Profile::Profiles.load(R::Profile::DEFAULT_ID)

    it "accounts for every vocabulary path the profile ships" do
      leaves = []
      walk   = lambda do |node, path|
        if node.is_a?(Hash)
          node.each { |key, value| walk.call(value, path + [key]) }
        else
          leaves << path
        end
      end
      document.each do |key, value|
        next if METADATA_KEYS.include?(key)

        walk.call(value, [key])
      end

      expect(leaves.sort).to eq((MIGRATED_PATHS + NOT_MIGRATED_PATHS.keys).sort)
    end

    # The values under MIGRATED_PATHS, read from the shipped document, keeping
    # only the DISTINCTIVE ones: short bare words (`new`, `get`, `all`, the
    # operators) are ordinary Ruby and would match everywhere. What is left —
    # `perform_async`, `ApplicationRecord`, `Sidekiq::Job`, `find_or_create_by`,
    # `config/schedule.rb` — cannot appear as a literal in the collector for
    # any innocent reason.
    values = []
    collect_strings = lambda do |node|
      case node
      when Hash   then node.each_value { |v| collect_strings.call(v) }
      when Array  then node.each { |v| collect_strings.call(v) }
      when String then values << node
      end
    end
    # EXEMPT FROM THE VALUE SCAN (not from the migration). The seeded ingress
    # category NAMES double as EMITTED graph vocabulary — `Cache::Writer` keys
    # its per-category counts by the same words, and those are output, not
    # collector input. What migrated is the SET-MEMBERSHIP question
    # EntrypointDetector asks; the words themselves legitimately recur.
    VALUE_SCAN_EXEMPT = [%w[framework entrypoints seeded_categories]].freeze

    (MIGRATED_PATHS - VALUE_SCAN_EXEMPT).each { |path| collect_strings.call(document.dig(*path)) }

    distinctive = values.uniq
                        .select { |v| v.length >= 2 && (v.match?(%r{[:!?/_]}) || v.length >= 8) }
                        .reject { |v| v.include?(" ") }

    it "derives a non-trivial distinctive set (guards against a vacuous pass)" do
      expect(distinctive.length).to be >= 40
    end

    it "positive control: the scanner DOES find an un-migrated vocabulary word" do
      # `insert_before` is a Rack registration verb — declared NOT migrated
      # above — and it is still a `%w` member in lib/. If this stops matching,
      # every zero-hit result below is meaningless.
      expect(hits.call(/"insert_before"/)).not_to be_empty
    end

    distinctive.each do |value|
      it "#{value.inspect} appears in no lib/ literal" do
        expect(hits.call(/["']#{Regexp.escape(value)}["']/)).to be_empty
      end
    end
  end

  describe "every migrated artifact is live in the profile" do
    # Each row: the profile predicate, and a value the DOCUMENT declares for it
    # (read from the document — never retyped). A predicate that answers true
    # for a declared value and false for a sentinel is provably reading the
    # profile rather than a surviving constant.
    doc = R::Profile::Profiles.load(R::Profile::DEFAULT_ID)

    {
      operator?:                doc.dig("language", "operator_deny"),
      dynamic_dispatch_verb?:   doc.dig("language", "dynamic_dispatch_verbs"),
      resolvable_dispatch_verb?: doc.dig("language", "resolvable_dispatch_verbs"),
      orm_method?:              doc.dig("framework", "orm", "methods").map { |m| m["name"] },
      orm_base?:                doc.dig("framework", "orm", "base_classes"),
      controller_base?:         doc.dig("framework", "controllers", "base_classes"),
      controller_name_suffix?:  doc.dig("framework", "controllers", "name_suffixes"),
      job_mixin?:               doc.dig("framework", "jobs", "mixins"),
      job_base?:                doc.dig("framework", "jobs", "base_classes"),
      job_dispatch_verb?:       doc.dig("framework", "jobs", "dispatch_verbs"),
      seeded_category?:         doc.dig("framework", "entrypoints", "seeded_categories"),
      script_dir?:              doc.dig("framework", "scripts", "dirs"),
      script_loader_call?:      doc.dig("framework", "scripts", "loader_only_calls"),
      cron_runner_verb?:        doc.dig("framework", "cron", "runner_target_verbs"),
      egress_root?:             doc.dig("library", "egress").flat_map { |e| e["roots"] },
      egress_verb?:             doc.dig("library", "egress").flat_map { |e| e["verbs"].map { |v| v["name"] } }
    }.each do |predicate, declared|
      it "##{predicate} answers from the profile's #{declared.length} declared values" do
        expect(declared).not_to be_empty
        declared.each { |value| expect(profile.public_send(predicate, value)).to be(true) }
        expect(profile.public_send(predicate, " not-a-declared-value")).to be(false)
      end
    end

    it "#egress_root? matches a declared root PREFIX, not just the exact roots" do
      prefix = doc.dig("library", "egress").flat_map { |e| e["root_prefixes"] }.first
      expect(prefix).not_to be_nil
      expect(profile.egress_root?("#{prefix}Some::Client")).to be(true)
    end

    it "carries the ordered lists as ordered lists (cron dialect precedence)" do
      expect(profile.cron_config_paths).to eq(doc.dig("framework", "cron", "config_paths"))
      expect(profile.cron_whenever_path).to eq(doc.dig("framework", "cron", "whenever_path"))
      expect(profile.category_precedence).to eq(doc.dig("framework", "entrypoints", "category_precedence"))
    end
  end
end
