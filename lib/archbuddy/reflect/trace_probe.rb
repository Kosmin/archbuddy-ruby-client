# frozen_string_literal: true

# STANDALONE RECEIVER-TYPE TRACE PROBE.
#
# Runs INSIDE THE TARGET APPLICATION'S PROCESS, like the boot probe, and depends
# on NOTHING but stdlib. Loaded ahead of the app (`RUBYOPT=-r<this file>`) so it
# can attach before the classes it watches exist.
#
# WHAT IT IS FOR. One population of call sites is undecidable by every static and
# reflective means: a receiver whose class answers calls out of an instance hash
# a CALLER filled in at runtime. `Interactor::Context` is the case that matters —
# `context.merchant` has no method to find, no owner to look up and no bytecode
# to read, because the value was placed there by a different file. The
# dynamic-interface classifier calls this shape a `bag` and can prove it is
# hopeless; only an execution can say what is actually in it.
#
# WHY THIS IS NOT "TRACE THE WHOLE APP". A global TracePoint costs 4-7x wall
# clock and produces a call graph we already have. This attaches TARGETED
# TracePoints — `enable(target:)`, one per bag-source `method_missing` — so it
# fires ONLY on the undecidable case. Measured on a real service: 1.0x, i.e.
# free, while a global :return trace over the same workload cost 4.3x.
#
# THE OUTPUT IS ADDITIVE AND OPTIONAL, and must stay that way. A trace is
# PARTIAL (it sees only what ran) and NON-DETERMINISTIC (it varies with inputs
# and ordering), whereas the graph and the boot manifest are complete over their
# domains and reproducible. Those cannot be merged: once absence might mean "not
# exercised", "this node has no callers" stops being a fact. So this writes its
# own file, nothing requires it, and its absence changes no score.
module ArchbuddyTraceProbe
  VERSION = "1"

  # (receiver_class, name) => { observed_class => count }. A SET, not a single
  # value, because two flows can legitimately put different types under one key
  # and picking one would be a fabrication. The consumer decides what to do with
  # an ambiguous key; the probe's job is to report honestly that it is ambiguous.
  OBSERVED = {}
  # Sources whose method_missing we have attached to, and those still waiting
  # for their class to be defined.
  ATTACHED = {}
  PENDING  = {}
  TRACERS  = [] # held so the TracePoints are not garbage collected

  class << self
    # @param root [String] project root; reads .archbuddy/reflection.json for the
    #   bag-source list produced by `archbuddy reflect`
    def install!(root = ENV.fetch("ARCHBUDDY_TRACE_ROOT", Dir.pwd))
      @root = root
      @out  = ENV["ARCHBUDDY_TRACE_OUT"] || File.join(root, ".archbuddy", "receiver_types.json")
      names = bag_sources(root)
      return warn_no_sources if names.empty?

      names.each { |n| defined_module(n) ? attach(n) : (PENDING[n] = true) }
      watch_for_pending! unless PENDING.empty?
      at_exit { write! }
      true
    end

    # WHICH CLASSES ARE BAGS is not re-derived here. `archbuddy reflect` already
    # classified every dynamic interface from the bytecode of its
    # `method_missing`; recomputing it in a second place would be a second source
    # of the same canon, and this file cannot require the code that does it.
    def bag_sources(root)
      require "json"
      path = File.join(root, ".archbuddy", "reflection.json")
      return [] unless File.file?(path)

      doc = JSON.parse(File.read(path))
      (doc.dig("dynamic_interfaces", "sources") || {})
        .select { |_name, meta| meta["kind"] == "bag" }.keys
    rescue StandardError
      []
    end

    # TWO hooks per source, and `enable(target:)` is what makes either
    # affordable: the VM fires for one method rather than for every return in
    # the process (measured 1.0x against 4.3x for a global :return trace).
    #
    # BOTH ARE NEEDED, because method_missing alone is VERSION-DEPENDENT and
    # fails silently where it does not apply. Measured on the same script:
    #
    #                                       ruby 2.7.5   ruby 3.4.2
    #   key set at construction, then read      fires     DOES NOT FIRE
    #   key assigned after construction         fires     fires
    #
    # Ruby 3's OpenStruct defines its members eagerly, so the common case — a
    # context built with all its keys — never misses and a method_missing-only
    # probe would report an empty trace on a modern app while looking healthy.
    # `initialize` receives the whole hash and behaves IDENTICALLY on both
    # versions, so it carries the bulk; method_missing then adds the keys
    # assigned later. Neither alone is sufficient.
    def attach(name)
      mod = defined_module(name) or return false

      ok = false
      ok |= hook(mod, :method_missing) { |t| record_missing(t) }
      ok |= hook(mod, :initialize) { |t| record_initialize(t) }
      return false unless ok

      ATTACHED[name] = true
      PENDING.delete(name)
      true
    rescue StandardError
      false
    end

    def hook(mod, method_name, &blk)
      um = mod.instance_method(method_name)
      tp = TracePoint.new(:return, &blk)
      tp.enable(target: um)
      TRACERS << tp
      true
    rescue StandardError
      # A Ruby without targeted enable, a C-defined or absent method, a frozen
      # module: learn nothing from this hook rather than fail the traced run.
      false
    end

    # Bag sources are often defined by the application's own dependencies, which
    # do not exist yet when this file is preloaded. `:end` fires once per class
    # body, so watching it is cheap, and the watcher retires as soon as every
    # pending source is attached.
    def watch_for_pending!
      watcher = TracePoint.new(:end) do |t|
        n = (t.self.name rescue nil)
        next unless n && PENDING.key?(n)

        attach(n)
        watcher_disable! if PENDING.empty?
      end
      @watcher = watcher
      watcher.enable
      TRACERS << watcher
    end

    def watcher_disable!
      @watcher&.disable
    end

    # THE RECORD. `method_missing(mid, *args)` carries the missed name as its
    # FIRST parameter, read off the frame by its DECLARED name rather than a
    # guessed one, so a gem that calls it something other than `mid` still works.
    #
    # nil is counted but never treated as a type: observing that
    # `context.merchant` was nil once says nothing about what it holds, and
    # promoting NilClass to "the type" would be worse than saying nothing.
    def record_missing(tp)
      name = missed_name(tp) or return

      note(safe_class(tp.self), name.to_s, tp.return_value.class)
    rescue StandardError
      nil
    end

    # `initialize(hash)` carries every key the object was built with, and the
    # VALUES are the types we want. Read positionally by declared parameter name
    # for the same reason as method_missing: the signature is the gem's, not ours.
    def record_initialize(tp)
      first = tp.parameters.first&.last
      return if first.nil?

      hash = tp.binding.local_variable_get(first)
      return unless hash.is_a?(Hash)

      cls = safe_class(tp.self)
      hash.each { |k, v| note(cls, k.to_s, v.class) }
    rescue StandardError
      nil
    end

    def note(receiver_class, name, value_class)
      cls = value_class.name
      return if receiver_class.empty? || cls.nil? || cls.empty?

      # A WRITE tells us the key's type as surely as a read does, so `later=`
      # is recorded under `later`. This is not cosmetic: assigning a key is
      # usually the ONLY miss that happens, because the assignment defines the
      # member and every later read hits a real method. Keying the setter
      # separately would file the observation under a name no call site uses.
      name = name.chomp("=")
      bucket = (OBSERVED[[receiver_class, name]] ||= {})
      bucket[cls] = (bucket[cls] || 0) + 1
    rescue StandardError
      nil
    end

    def missed_name(tp)
      first = tp.parameters.first&.last
      return nil if first.nil?

      tp.binding.local_variable_get(first)
    rescue StandardError
      nil
    end

    # NEVER `obj.class`. The objects we are tracing are precisely the ones that
    # intercept unknown methods, and several of them — FactoryBot's
    # DefinitionProxy, RSpec's matcher proxies — are BLANK SLATES that intercept
    # `class` too. Asking them politely returns whatever their method_missing
    # decides and re-enters the very hook we are inside.
    #
    # Measured before this was bound: 513 of 584 observations were filed under a
    # receiver class literally named "class", because that is what the proxy
    # answered. Binding Object#class reads the real class without dispatching
    # through the object at all.
    CLASS_OF = ::Object.instance_method(:class)

    def safe_class(obj)
      CLASS_OF.bind(obj).call.name.to_s
    rescue StandardError
      # BasicObject descendants cannot be bound this way; better to record
      # nothing than to record a name the object made up.
      ""
    end

    def defined_module(name)
      Object.const_get(name)
    rescue StandardError
      nil
    end

    def manifest
      {
        "schema"     => VERSION,
        "ruby"       => RUBY_VERSION,
        "attached"   => ATTACHED.keys.sort,
        # Sources we never got to attach to. Published so a thin result is
        # visibly a coverage problem rather than silently "nothing to find".
        "unattached" => PENDING.keys.sort,
        "types"      => OBSERVED.map { |(cls, name), counts|
          { "class" => cls, "name" => name, "observed" => counts }
        }.sort_by { |r| [r["class"], r["name"]] }
      }
    end

    def write!
      require "json"
      require "fileutils"
      FileUtils.mkdir_p(File.dirname(@out))
      File.write(@out, JSON.pretty_generate(manifest))
      warn "archbuddy-trace: #{OBSERVED.size} (receiver, name) pairs observed -> #{@out}"
    rescue StandardError => e
      warn "archbuddy-trace: could not write #{@out} (#{e.class})"
    end

    def warn_no_sources
      warn "archbuddy-trace: no `bag` dynamic-interface sources in reflection.json " \
           "(run `archbuddy reflect` first); nothing to trace"
      false
    end
  end
end

ArchbuddyTraceProbe.install! if ENV["ARCHBUDDY_TRACE"] == "1"
