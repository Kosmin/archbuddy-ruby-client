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
  VERSION = "1"

  module_function

  # @param root [String] absolute project root; only methods whose source_location
  #   is INSIDE this root are recorded (gem and stdlib methods are irrelevant and
  #   would dwarf the app).
  # @return [Hash] the manifest
  def capture(root)
    root = File.expand_path(root)
    classes = each_named_module.select { |m| touches?(m, root) }
    entries = classes.flat_map { |mod| methods_for(mod, root) }.compact
    {
      "schema"      => VERSION,
      "root"        => root,
      "ruby"        => RUBY_VERSION,
      "captured_at" => Time.now.utc.iso8601,
      "classes"     => classes.map { |m| safe_name(m) }.compact.sort,
      "methods"     => entries
    }
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

  def own_methods(mod)
    inst = (mod.instance_methods(false) +
            mod.private_instance_methods(false) +
            mod.protected_instance_methods(false)).map { |n| [:instance, n] }
    sing = mod.singleton_methods(false).map { |n| [:singleton, n] }
    inst + sing
  rescue StandardError
    []
  end

  def location_for(mod, kind, name)
    um = kind == :instance ? mod.instance_method(name) : mod.singleton_class.instance_method(name)
    um.source_location
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
      um = kind == :instance ? mod.instance_method(name) : mod.singleton_class.instance_method(name)
      {
        "class"      => cls,
        "name"       => name.to_s,
        "scope"      => kind.to_s,
        "file"       => loc ? relative(loc[0], root) : nil,
        "external_site" => loc ? !loc[0].to_s.start_with?(root) : nil,
        "line"       => loc ? loc[1] : nil,
        "arity"      => safe_arity(um),
        "visibility" => visibility_of(mod, kind, name)
      }
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

  def safe_name(mod)
    n = mod.name
    n && !n.empty? ? n : nil
  rescue StandardError
    nil
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

if $PROGRAM_NAME == __FILE__ || ENV["ARCHBUDDY_REFLECT_OUT"]
  require "json"
  require "time"
  target = ENV.fetch("ARCHBUDDY_REFLECT_ROOT", Dir.pwd)
  out    = ENV.fetch("ARCHBUDDY_REFLECT_OUT", File.join(target, ".archbuddy", "reflection.json"))
  require "fileutils"
  FileUtils.mkdir_p(File.dirname(out))
  m = ArchbuddyReflectProbe.write(target, out)
  warn "archbuddy-reflect: #{m['methods'].size} methods across #{m['classes'].size} classes -> #{out}"
end
