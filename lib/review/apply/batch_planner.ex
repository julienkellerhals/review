defmodule Review.Apply.BatchPlanner do
  @moduledoc false

  def plan(jobs, concurrency) do
    jobs
    |> do_plan(concurrency, [])
    |> Enum.reverse()
  end

  defp do_plan([], _concurrency, batches), do: batches

  defp do_plan(jobs, concurrency, batches) do
    {batch, remaining} = take_non_conflicting_batch(jobs, concurrency)
    do_plan(remaining, concurrency, [batch | batches])
  end

  defp take_non_conflicting_batch(jobs, concurrency) do
    {batch, _affected_files, remaining} =
      Enum.reduce(jobs, {[], [], []}, fn job, {batch, affected_files, remaining} ->
        if length(batch) < concurrency and
             disjoint_affected_paths?(affected_files, job.affected_files) do
          {[job | batch], affected_files ++ job.affected_files, remaining}
        else
          {batch, affected_files, [job | remaining]}
        end
      end)

    {Enum.reverse(batch), Enum.reverse(remaining)}
  end

  defp disjoint_affected_paths?(left_paths, right_paths) do
    Enum.all?(left_paths, fn left ->
      Enum.all?(right_paths, fn right ->
        not affected_paths_conflict?(left, right)
      end)
    end)
  end

  defp affected_paths_conflict?(left, right) do
    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/")
  end
end
