# frozen_string_literal: true

require "tmpdir"
require "archbuddy/config"

# v0.15 P1-T2: precedence — CLI > file > defaults (L4/L3).
RSpec.describe "Config precedence" do
  def load_config(yaml, cli: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".archbuddy.yml"), yaml) if yaml
      return Archbuddy::Config.load(target_root: dir, cli: cli)
    end
  end

  it "CLI --fail-level beats the file" do
    config = load_config("version: 1\nall: { fail_level: warn }\n", cli: { fail_level: :error })
    expect(config.effective_fail_level).to eq(:error)
  end

  it "CLI advisory forces :none" do
    config = load_config("version: 1\nall: { fail_level: error }\n", cli: { advisory: true })
    expect(config.effective_fail_level).to eq(:none)
    expect(config.gating?).to be(false)
  end

  it "no file + no CLI → :none (advisory default, L3)" do
    expect(load_config(nil).effective_fail_level).to eq(:none)
  end

  it "file present + no keys → :error (starter default)" do
    expect(load_config("version: 1\n").effective_fail_level).to eq(:error)
  end

  it "file all.fail_level honored when no CLI given" do
    expect(load_config("version: 1\nall: { fail_level: info }\n").effective_fail_level).to eq(:info)
  end

  it "format: CLI > file > terminal" do
    expect(load_config("version: 1\nall: { format: markdown }\n").format).to eq("markdown")
    expect(load_config("version: 1\nall: { format: markdown }\n", cli: { format: "json" }).format).to eq("json")
    expect(load_config("version: 1\n").format).to eq("terminal")
  end
end
