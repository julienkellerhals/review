defmodule Mix.Tasks.Review.Apply do
  use Mix.Task

  @shortdoc "Apply generated review markdown files"

  @moduledoc """
  Applies generated review markdown files.

      $ mix review.apply
      $ mix review.apply review/path/to/review.md
      $ mix review.apply --profile one

  Environment variables such as `REVIEW_DIR`, `REVIEW_SOURCE_BLACKLIST`,
  `CODEX_MODEL`, `CODEX_APPLY_REASONING_EFFORT`, `CODEX_REVIEW_REASONING_EFFORT`,
  `CODEX_FIX_REVIEW_MAX_ATTEMPTS`, `CODEX_COMMAND_MAX_ATTEMPTS`, and
  `CODEX_APPLY_CONCURRENCY` control the apply run.

  Define `profiles: [one: [...], two: [...]]` in `config :review` and select
  one with `--profile one` for per-subproject config.
  """

  @impl Mix.Task
  def run(args) do
    run_review_task(fn -> Review.Apply.main(args) end)
  end

  defp run_review_task(fun) do
    fun.()
  rescue
    exception in [Review.Error] ->
      Mix.raise(Exception.message(exception))

    exception ->
      Mix.raise("Unexpected review.apply failure: #{Exception.message(exception)}")
  catch
    kind, reason ->
      Mix.raise("Unexpected review.apply #{kind}: #{inspect(reason)}")
  end
end
