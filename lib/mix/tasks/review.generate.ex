defmodule Mix.Tasks.Review.Generate do
  use Mix.Task

  @shortdoc "Generate architecture review markdown files"

  @moduledoc """
  Generates architecture review markdown files.

      $ mix review.generate
      $ mix review.generate lib/my_app/example.ex

  Environment variables such as `REVIEW_DIR`, `REVIEW_CONCURRENCY`,
  `REVIEW_SOURCE_BLACKLIST`, `REVIEW_RECOMMENDATION_LIMIT`, `CODEX_MODEL`, and
  `CODEX_REASONING_EFFORT` control the review run.
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
