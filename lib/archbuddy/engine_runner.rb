# frozen_string_literal: true

module Archbuddy
  # The ONE engine shell-out seam (v0.16 T11, Q6/D-C2): invoke the engine
  # `analyze` the way a user does — prefer the bundled binstub (`bundle exec
  # architecture-auditor`), fall back to a plain `architecture-auditor` on
  # PATH. Extracted VERBATIM from cli/analyze.rb's ladder so `archbuddy
  # analyze` and the `diff --analyze-sides` transport share one invocation
  # path (one owner of the engine-resolution story).
  #
  # Failure RAISES EngineError — callers decide the exit discipline:
  # cli/analyze keeps its historical `exit 1` contract at the CLI layer;
  # the review lane maps it to VintageError → exit 2 (stdout EMPTY).
  #
  # CLEAN-STDOUT (P5): in diff context the engine subprocess must never
  # write to the client's stdout (the rendered document is stdout's only
  # write) — callers pass `stdout: $stderr` to route the engine's stdout
  # to stderr via the `system(..., out: $stderr)` spawn option. The default
  # (nil) inherits the parent's stdout — `archbuddy analyze` behavior is
  # byte-identical to the pre-extraction ladder.
  module EngineRunner
    # Raised when neither rung of the ladder completes successfully
    # (engine absent from the bundle AND from PATH, or analyze exited
    # nonzero on both attempts).
    class EngineError < StandardError; end

    module_function

    # @param graph_yml [String] path to the opaque graph.yml to analyze
    # @param out [String] path the engine writes findings.yml to
    # @param stdout [IO, nil] where the ENGINE subprocess's stdout goes;
    #   nil inherits (analyze CLI), $stderr keeps diff's stdout clean
    # @return [true]
    # @raise [EngineError] when both ladder rungs fail
    def analyze(graph_yml, out:, stdout: nil)
      redirect = stdout ? { out: stdout } : {}
      ok = system("bundle", "exec", "architecture-auditor", "analyze",
                  graph_yml, "--out", out, **redirect)
      ok ||= system("architecture-auditor", "analyze",
                    graph_yml, "--out", out, **redirect)
      return true if ok

      raise EngineError,
            "engine `architecture-auditor analyze` failed for #{graph_yml} " \
            "(tried `bundle exec architecture-auditor`, then PATH)"
    end
  end
end
