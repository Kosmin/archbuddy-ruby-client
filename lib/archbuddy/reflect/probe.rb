# frozen_string_literal: true

# STANDALONE BOOT-REFLECTION PROBE.
#
# This file runs INSIDE THE TARGET APPLICATION'S PROCESS (via `rails runner`,
# `ruby -r`, or a rake task), where archbuddy is NOT in the Gemfile. It therefore
# depends on NOTHING but stdlib and MUST NOT require any archbuddy code. Its only
# output is a JSON manifest on disk, which `archbuddy collect --reflection` reads
# back in a separate process.
#
# WHY THIS EXISTS: static parsing cannot see methods that do not appear as `def`
# in source — `attr_accessor`, `has_many`, `delegate`, scopes, `define_method`.
# In a Rails model those are the majority of the public surface. They come into
# existence when the class body EXECUTES, so merely LOADING the app reveals them;
# no test suite, no traffic, no fixtures are required.
#
# It records WHERE each method came from (`source_location`), which is what lets
# the consumer separate a generated trivial accessor from a hand-written one:
# a real `def customer=` and an `attr_accessor :customer` are indistinguishable
# by name but differ by source line.
module ArchbuddyReflectProbe
  VERSION = "3"

  # CONSTANT PROVENANCE — which constants this application defines, and from
  # which file. This is what makes "is this receiver app code or an exit?"
  # a FACT rather than an inference, and unlike method names, constants are
  # unique addresses so the answer is unambiguous.
  #
  # Four sources, all OPTIONAL and additive. None is required, because no single
  # one is universal:
  #   * TracePoint(:class) — the INTERPRETER reporting every class/module body it
  #     opens, with the file. Works under Zeitwerk, the classic autoloader, bare
  #     `require`, or no framework at all. This is the only universal source, and
  #     the reason we do not hook a specific autoloader: a real Rails 6.1 app was
  #     measured on `autoloader: :classic`, where a Zeitwerk hook returns NOTHING.
  #   * Zeitwerk    — `all_expected_cpaths` additionally covers constants that
  #     were never loaded, which execution alone cannot see.
  #   * classic     — ActiveSupport::Dependencies.autoloaded_constants.
  #   * $LOADED_FEATURES — the universal floor: every file actually loaded.
  CONSTANTS = {}

  # Must be enabled BEFORE the application is required, or the class bodies have
  # already run and the events are gone.
  def self.watch_constants!
    @tp ||= TracePoint.new(:class) do |t|
      name = (t.self.name rescue nil)
      # ALL definition sites, not just the first.
      #
      # A Rails engine defines `User`, and the host application REOPENS it — both
      # are real definitions of the same constant. Recording only the first made
      # every such class look like engine code, because the engine loads first:
      # measured, that misclassified User/Merchant/Purchase/Reward/Membership —
      # the core domain models, 300+ call sites — as EXITS, truncating the graph
      # at its most connected nodes. A constant is app code if ANY of its
      # definition sites is in the app.
      if name
        (CONSTANTS[name] ||= []) << t.path unless CONSTANTS[name]&.include?(t.path)
      end
    end
    @tp.enable
    @tp
  end

  def self.stop_watching!
    @tp&.disable
  end

  def self.zeitwerk_cpaths
    return {} unless defined?(::Zeitwerk::Registry)

    loaders = (::Zeitwerk::Registry.loaders rescue [])
    loaders.each_with_object({}) do |l, acc|
      next unless l.respond_to?(:all_expected_cpaths)

      (l.all_expected_cpaths rescue {}).each { |file, cpath| acc[cpath] ||= file.to_s }
    end
  rescue StandardError
    {}
  end

  def self.classic_cpaths
    return {} unless defined?(::ActiveSupport::Dependencies)
    return {} unless ::ActiveSupport::Dependencies.respond_to?(:autoloaded_constants)

    (::ActiveSupport::Dependencies.autoloaded_constants || []).each_with_object({}) { |c, acc| acc[c] ||= nil }
  rescue StandardError
    {}
  end

  module_function

  # @param root [String] absolute project root; only methods whose source_location
  #   is INSIDE this root are recorded (gem and stdlib methods are irrelevant and
  #   would dwarf the app).
  # @return [Hash] the manifest
  def capture(root)
    # realpath, NOT expand_path. `source_location` reports the REAL path, so a
    # project reached through a symlink (macOS /tmp -> /private/tmp, symlinked
    # home or code dirs, network mounts) would compare false against an
    # expand_path root and reflect ZERO methods — silently, since an empty
    # manifest is indistinguishable from "this app has no classes".
    root = begin
      File.realpath(root)
    rescue StandardError
      File.expand_path(root)
    end
    classes = each_named_module.select { |m| touches?(m, root) }
    entries = classes.flat_map { |mod| methods_for(mod, root) }.compact
    {
      "schema"      => VERSION,
      "root"        => root,
      "ruby"        => RUBY_VERSION,
      "captured_at" => Time.now.utc.iso8601,
      "classes"     => classes.map { |m| safe_name(m) }.compact.sort,
      "constants"   => constant_provenance(root),
      "loaded_files" => $LOADED_FEATURES.select { |f| app_path?(f, root) }.map { |f| relative(f, root) },
      "methods"     => entries
    }
  end

  # cpath => { "file" => path|nil, "app" => bool }. Merged from every available
  # source; TracePoint wins because it observed the definition happen.
  def constant_provenance(root)
    merged = Hash.new { |h, k| h[k] = [] }
    zeitwerk_cpaths.each { |cpath, file| merged[cpath] << file if file }
    classic_cpaths.each  { |cpath, file| merged[cpath] << file if file }
    CONSTANTS.each       { |cpath, files| merged[cpath].concat(Array(files)) }
    merged.each_with_object({}) do |(cpath, files), acc|
      files = files.compact.uniq
      app = files.any? { |f| app_path?(f, root) }
      acc[cpath] = {
        # The APP definition when there is one, so provenance points at the code
        # a reader can actually open; otherwise the first foreign site.
        "file"  => (files.find { |f| app_path?(f, root) } || files.first)&.then { |f| relative(f, root) },
        "app"   => app,
        "sites" => files.size
      }
    end
  end

  # A path belongs to the APPLICATION only if it is under the root AND not inside
  # a dependency directory. Bundled gems install UNDER the project root (devbox
  # puts them in .devbox/virtenv, bundler in vendor/bundle), so a bare
  # start_with?(root) test classifies every gem as app code — measured
  # misclassifying Logger, and it would have poisoned the whole exit rule.
  VENDOR = %w[/vendor/ /.bundle/ /.devbox/ /gems/ /node_modules/].freeze

  def app_path?(path, root)
    p = path.to_s
    return false unless p.start_with?(root.to_s)

    VENDOR.none? { |v| p.include?(v) }
  end

  def each_named_module
    out = []
    ObjectSpace.each_object(Module) do |m|
      next if m.singleton_class?

      out << m if safe_name(m)
    end
    out
  end

  # A module BELONGS to the project when at least one of its own methods was
  # defined by a file under root. Checking the methods (not the constant) is what
  # keeps reopened core classes and gem modules out. Once a module qualifies, ALL
  # of its own methods are recorded — including gem-generated ones, which are the
  # point.
  def touches?(mod, root)
    own_methods(mod).any? do |kind, name|
      loc = location_for(mod, kind, name)
      loc && loc[0].to_s.start_with?(root)
    end
  rescue StandardError
    false
  end

  # Methods the class OWNS, including those supplied by generated ancestor
  # modules.
  #
  # `instance_methods(false)` alone is not enough. Rails does not define an
  # association on the model — it defines it on a `GeneratedAssociationMethods`
  # module that it includes, and the same for schema-derived attribute methods.
  # Those are exactly the methods boot reflection exists to find, so a
  # false-only walk would miss the entire point on the framework that motivates
  # this feature.
  #
  # We therefore also sweep ancestor modules that are ANONYMOUS or whose name
  # marks them as generated. That targets the metaprogramming case without
  # sweeping in every gem mixin a class happens to include.
  def own_methods(mod)
    sources = [mod] + generated_ancestors(mod)
    inst = sources.flat_map do |m|
      m.instance_methods(false) + m.private_instance_methods(false) +
        m.protected_instance_methods(false)
    end.uniq.map { |n| [:instance, n] }
    sing = mod.singleton_methods(false).map { |n| [:singleton, n] }
    inst + sing
  rescue StandardError
    []
  end

  GENERATED_MODULE = /Generated|_methods\z/i.freeze

  def generated_ancestors(mod)
    mod.ancestors.reject { |a| a.equal?(mod) }.select do |a|
      next false unless a.is_a?(Module) && !a.is_a?(Class)

      nm = safe_name(a)
      nm.nil? || nm.match?(GENERATED_MODULE)
    end
  rescue StandardError
    []
  end

  def location_for(mod, kind, name)
    um = unbound(mod, kind, name)
    um&.source_location
  rescue StandardError
    nil
  end

  def unbound(mod, kind, name)
    kind == :instance ? mod.instance_method(name) : mod.singleton_class.instance_method(name)
  rescue StandardError
    nil
  end

  def methods_for(mod, root)
    cls = safe_name(mod)
    return [] unless cls

    own_methods(mod).filter_map do |kind, name|
      loc = location_for(mod, kind, name)
      # NOTE: we deliberately do NOT filter on the definition SITE being inside
      # the project. A `has_many` association method is OWNED by the app's model
      # but DEFINED inside the activerecord gem — filtering by site would drop
      # precisely the methods this whole feature exists to capture. Ownership is
      # the correct test; the site is recorded as data (and may legitimately be
      # outside the root, which the consumer uses to spot gem-generated methods).
      um = unbound(mod, kind, name)
      next if um.nil?

      external = external_site(loc, root)
      entry = {
        "class"      => cls,
        "name"       => name.to_s,
        "scope"      => kind.to_s,
        "file"       => loc ? relative(loc[0], root) : nil,
        "external_site" => external,
        "line"       => loc ? loc[1] : nil,
        "arity"      => safe_arity(um),
        "owner"      => safe_name(um.owner),
        "visibility" => visibility_of(mod, kind, name)
      }
      # Recorded ONLY for methods whose definition site is APPLICATION source,
      # for two independent reasons.
      #
      # HONESTY: ActiveRecord's association reader is a generic runtime shim —
      # `association(:merchant).reader` — which is itself a two-send forwarder
      # and would be read as "forwards to #association", naming AR's internals
      # instead of the association's target. That shim lives in the gem, so
      # gating on the definition site rules it out BY CONSTRUCTION rather than
      # by a vocabulary of method names to distrust. An association's real
      # target is recoverable, but only through a framework-specific reflection
      # API, which is a different tier and does not belong in this file.
      #
      # SIZE: a real service reflects ~130k gem methods against ~6k of its own.
      # Forwarding facts about gem internals are inert to every consumer, and
      # the manifest is already the largest artifact we write.
      #
      # THE GATE IS `app_path?`, NOT `external_site`. Those two disagree, and
      # the difference is the whole point: bundled gems install UNDER the
      # project root, so `external_site` — a bare root-prefix test — reports a
      # vendored gem as in-app. Gating on it produced 30,930 facts from
      # .devbox/virtenv against 1,349 real ones, 25,546 of them the very AR
      # shim this gate exists to exclude.
      #
      # The key is OMITTED, not set to null, when there is nothing to say — the
      # same discipline as every other absent fact here.
      fwd = loc && app_path?(loc[0], root) ? forwards_for(um) : nil
      entry["forwards"] = fwd if fwd
      entry
    end
  end

  def visibility_of(mod, kind, name)
    return "public" if kind == :singleton
    return "private" if mod.private_instance_methods(false).include?(name)
    return "protected" if mod.protected_instance_methods(false).include?(name)

    "public"
  end

  def safe_arity(um)
    um.arity
  rescue StandardError
    nil
  end

  # FORWARDING RECOVERY — the framework-AGNOSTIC half of DSL decomposition.
  #
  # A method a DSL generated has no `def` in source, so a parser can never read
  # its body. But the method EXISTS once the class body has run, and CRuby will
  # hand back the bytecode it compiled for it. Disassembling that recovers what
  # the body DOES without knowing which macro wrote it: ActiveSupport's
  # `delegate`, Forwardable's `def_delegator` and a hand-rolled
  # `define_method(:x) { y.z }` all compile to the same shape, so one rule reads
  # all three and any future one.
  #
  # THE SHAPE. A forwarder evaluates ONE receiverless call, stores it, and sends
  # ONE method to the result:
  #
  #     putself
  #     opt_send_without_block  <calldata!mid:purchase, argc:0, FCALL|VCALL|...>
  #     setlocal                _
  #     getlocal                _
  #     send                    <calldata!mid:merchant, ...>
  #     leave
  #
  # so the MAIN BODY contains EXACTLY TWO sends — the target, then the forwarded
  # name. Two is the whole test. Anything else is not a forwarder and we return
  # nil rather than guess.
  #
  # ONLY THE MAIN BODY. `delegate` also compiles a rescue clause that raises
  # DelegationError; its instructions (`nil?`, `name`, `inspect`, `raise`) appear
  # in the disassembly indented under a catch table. Dropping the catch-table
  # lines first is what keeps the count at two — and, deliberately, it is also
  # what keeps this rule from depending on ActiveSupport's error TEXT, which is
  # the sort of vocabulary this whole approach exists to avoid.
  FORWARD_MID  = /mid:([a-zA-Z_][a-zA-Z0-9_]*[?!=]?)/.freeze
  RECEIVERLESS = /FCALL|VCALL/.freeze

  # @return [Hash, nil] {"to" =>, "via" =>}, or nil when not a forwarder
  def forwards_for(um)
    return nil unless defined?(RubyVM::InstructionSequence)

    iseq = RubyVM::InstructionSequence.of(um)
    return nil if iseq.nil? # C-defined (attr_* and friends) — no bytecode to read

    parse_forward(iseq.disasm)
  rescue StandardError
    # Bytecode introspection is an ENRICHMENT. A Ruby without RubyVM, a JIT that
    # declines, a method whose iseq was GC'd — all mean "we learned nothing
    # here", never "the method does not forward".
    nil
  end

  # Split out from `forwards_for` as a PURE FUNCTION of the disassembly text, so
  # the rule above can be tested against recorded bytecode without booting an
  # application to produce it.
  def parse_forward(disasm)
    body  = disasm.lines.reject { |l| l.start_with?("|") }
    sends = body.select { |l| l.include?("mid:") }
    return nil unless sends.length == 2
    return nil unless RECEIVERLESS.match?(sends[0])

    to  = sends[0][FORWARD_MID, 1]
    via = sends[1][FORWARD_MID, 1]
    return nil if to.nil? || via.nil?

    { "to" => to, "via" => via }
  end

  def safe_name(mod)
    n = mod.name
    n && !n.empty? ? n : nil
  rescue StandardError
    nil
  end

  # Whether the DEFINITION lives outside the project tree.
  #
  # nil — not false — when the location is not a real filesystem path.
  # `define_method` inside an `eval`, and C-defined methods, report "(eval)" or
  # "<internal:...>", which start with neither the project root nor anything
  # else meaningful. Treating "does not start with root" as PROVEN EXTERNAL
  # would fabricate a crossing for a method the application itself defined —
  # measured at 505 of 10,121 on a real service. Unknown provenance is ABSENT,
  # never asserted in either direction.
  def external_site(loc, root)
    return nil if loc.nil?

    path = loc[0].to_s
    return nil unless path.start_with?("/")

    !path.start_with?(root)
  end

  def relative(path, root)
    p = path.to_s
    p.start_with?(root) ? p[(root.length + 1)..] : p
  end

  def write(root, out_path)
    require "json"
    require "time"
    manifest = capture(root)
    File.write(out_path, JSON.pretty_generate(manifest))
    manifest
  end
end

# Required EARLY (before the app) this only arms the watcher; required late it
# writes the manifest. One file, two phases, so a boot script can simply require
# it first and last.
if ENV["ARCHBUDDY_REFLECT_WATCH"]
  ArchbuddyReflectProbe.watch_constants!
elsif $PROGRAM_NAME == __FILE__ || ENV["ARCHBUDDY_REFLECT_OUT"]
  require "json"
  require "time"
  target = ENV.fetch("ARCHBUDDY_REFLECT_ROOT", Dir.pwd)
  out    = ENV.fetch("ARCHBUDDY_REFLECT_OUT", File.join(target, ".archbuddy", "reflection.json"))
  require "fileutils"
  FileUtils.mkdir_p(File.dirname(out))
  ArchbuddyReflectProbe.stop_watching!
  m = ArchbuddyReflectProbe.write(target, out)
  app_consts = (m["constants"] || {}).count { |_, v| v["app"] }
  warn "archbuddy-reflect: #{m['methods'].size} methods across #{m['classes'].size} classes, " \
       "#{(m['constants'] || {}).size} constants (#{app_consts} app-defined) -> #{out}"
end
