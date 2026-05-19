defmodule Mix.Tasks.Review.Generate do
  use Mix.Task

  @shortdoc "Generate review markdown files"

  @moduledoc """
  Generates review markdown files.

      $ mix review.generate
      $ mix review.generate lib/my_app/example.ex
      $ mix review.generate --profile one
      $ mix review.generate --resume lib/my_app/example.ex

  Configure Codex with `codex_model`, `codex_reasoning_effort`, and
  `codex_fast_mode` in `config :review`. Environment variables such as
  `REVIEW_DIR`, `REVIEW_CONCURRENCY`, `REVIEW_SOURCE_BLACKLIST`, `CODEX_MODEL`,
  and `CODEX_REASONING_EFFORT` override config for one run. Set
  `REVIEW_TOOL_CHECK=0` to skip optional tooling checks.

  Configure default discovery roots in the consuming project's `config/config.exs`:

      config :review,
        review_dir: "review",
        source_dirs: ["lib", "test", "config"],
        source_dirs_mode: :discover,
        source_file_extensions: [".ex", ".exs", ".heex"],
        source_blacklist: [".git", "_build", "deps"],
        codex_reasoning_effort: "high",
        codex_fast_mode: true

  Set `source_dirs_mode: :whitelist` to make `source_dirs` an allow-list for
  explicit file arguments too. Define `profiles: [one: [...], two: [...]]` and
  select one with `--profile one` for per-subproject config.

  Generated reviews store a sibling `review.session` file. Use `--resume` to
  resume that per-source Codex session and rewrite the review instead of
  skipping an existing `review.md`.

  Without this config, the generator searches from the repository root.
  """

  @impl Mix.Task
  def run(args) do
    run_review_task(fn -> Review.Generate.main(args) end)
  end

  defp run_review_task(fun) do
    fun.()
  rescue
    exception in [Review.Error] ->
      Mix.raise(Exception.message(exception))

    exception ->
      Mix.raise("Unexpected review.generate failure: #{Exception.message(exception)}")
  catch
    kind, reason ->
      Mix.raise("Unexpected review.generate #{kind}: #{inspect(reason)}")
  end
end
