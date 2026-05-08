defmodule Mix.Tasks.Review.CleanupWorktrees do
  use Mix.Task

  @shortdoc "Remove linked Git worktrees for the current repository"

  @moduledoc """
  Removes linked Git worktrees for the current repository.

      $ mix review.cleanup_worktrees
  """

  @impl Mix.Task
  def run(args) do
    run_review_task(fn -> Review.Maintenance.CleanupWorktrees.main(args) end)
  end

  defp run_review_task(fun) do
    fun.()
  rescue
    exception in [Review.Error] ->
      Mix.raise(Exception.message(exception))

    exception ->
      Mix.raise("Unexpected review.cleanup_worktrees failure: #{Exception.message(exception)}")
  catch
    kind, reason ->
      Mix.raise("Unexpected review.cleanup_worktrees #{kind}: #{inspect(reason)}")
  end
end
