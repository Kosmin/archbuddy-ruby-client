# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# END-TO-END Rack middleware root seeder (v0.10 W2-B). Feeds inline
# middleware source through the REAL adapter and asserts that a middleware
# `#call` becomes a CATEGORIZED entrypoint ONLY under the full L8
# conjunction — `def call(env)` arity-1 + `@app` write in `#initialize` +
# a `use`-registration naming the constant — and DECLINES otherwise
# (never-fabricate: `#call(env)` alone is the weakest ingress signal).
#
# Pattern: Dir.mktmpdir + inline .rb fixtures + real adapter (same as
# job_seeder_spec.rb).
RSpec.describe "Rack middleware root seeder (v0.10 W2-B e2e)" do
  let(:config) { Archbuddy::Collect::Config.new(language: "ruby") }

  MW_CLASS = <<~RUBY
    class RequestTagger
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  RUBY

  REGISTRATION = <<~RUBY
    module MyApp
      class Application
        def self.configure(config)
          config.middleware.use RequestTagger
        end
      end
    end
  RUBY

  def anonymize(root, cfg = config)
    Archbuddy::Collect::Anonymizer.new(
      Archbuddy::Collect::Registry.for("ruby").new(root, cfg).collect,
      tool: "archbuddy test", adapter: "ruby"
    ).call
  end

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

  def entrypoint?(result, sym)
    entry = result.id_map["ids"].find { |_i, d| d["symbol"] == sym }
    return false unless entry

    result.graph["entrypoints"].include?(entry.first)
  end

  # --- the full conjunction seeds ------------------------------------------------

  it "seeds #call for a registered `config.middleware.use` middleware" do
    in_repo(
      "app/middleware/request_tagger.rb" => MW_CLASS,
      "config/application.rb"            => REGISTRATION
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "RequestTagger#call")).to be(true)
    end
  end

  it "seeds #call for a bare `use Mw` registration (Rack::Builder style)" do
    in_repo(
      "app/middleware/request_tagger.rb" => MW_CLASS,
      "config/builder.rb"                => "use RequestTagger\n"
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "RequestTagger#call")).to be(true)
    end
  end

  it "stamps the :middleware category on the seeded MethodEntry" do
    in_repo(
      "app/middleware/request_tagger.rb" => MW_CLASS,
      "config/application.rb"            => REGISTRATION
    ) do |dir|
      table = seeded_table(dir)
      expect(table.entrypoint_category("RequestTagger#call")).to eq(:middleware)
    end
  end

  # --- declines (L4/L8: prefer the false negative) --------------------------------

  it "DECLINES an unregistered middleware-shaped class" do
    in_repo("app/middleware/request_tagger.rb" => MW_CLASS) do |dir|
      expect(entrypoint?(anonymize(dir), "RequestTagger#call")).to be(false)
    end
  end

  it "DECLINES a registered class whose initialize never writes @app" do
    in_repo(
      "app/middleware/request_tagger.rb" => <<~RUBY,
        class RequestTagger
          def initialize(app)
            @application = app
          end

          def call(env)
            env
          end
        end
      RUBY
      "config/application.rb" => REGISTRATION
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "RequestTagger#call")).to be(false)
    end
  end

  it "DECLINES a registered class whose #call is not arity-1" do
    in_repo(
      "app/middleware/request_tagger.rb" => <<~RUBY,
        class RequestTagger
          def initialize(app)
            @app = app
          end

          def call(env, extra)
            env
          end
        end
      RUBY
      "config/application.rb" => REGISTRATION
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "RequestTagger#call")).to be(false)
    end
  end

  it "never lands an unrelated `client.use(x)` in the registration set" do
    in_repo(
      "app/middleware/request_tagger.rb" => MW_CLASS,
      "app/services/client_caller.rb"    => <<~RUBY
        class ClientCaller
          def go(client)
            client.use RequestTagger
          end
        end
      RUBY
    ) do |dir|
      expect(entrypoint?(anonymize(dir), "RequestTagger#call")).to be(false)
    end
  end

  # Run Pass 1 + the MiddlewareSeeder directly so the table (with its seeded
  # categories) is inspectable.
  def seeded_table(dir)
    m     = Archbuddy::Collect::Adapters::Ruby
    table = m::SymbolTable.new
    fragments = m::FileEnumerator.new(dir, config).files.map do |abs, rel|
      Archbuddy::Collect::Fragment.new(
        rel_file: rel, content_hash: "x", parsed_value: Prism.parse(File.read(abs)).value
      )
    end
    fragments.each { |f| f.parsed_value.accept(m::DefinitionPass.new(table, f.rel_file)) }
    m::RootSeeders::MiddlewareSeeder.new.seed(table, fragments: fragments, root: dir)
    table
  end
end
