defmodule Review.Apply.Lifecycle do
  @moduledoc false

  alias Review.Apply.Git
  alias Review.Apply.Worktree

  def ensure_ready!(root, target) do
    ensure_no_staged_changes!(root)
    ensure_clean_working_tree_except_reviews!(root, target)
  end

  def run_batch!(root, target, batch, opts) do
    apply_review = Keyword.fetch!(opts, :apply_review)
    skip_stale = Keyword.fetch!(opts, :skip_stale)
    started_branch = Keyword.fetch!(opts, :started_branch)

    root
    |> apply_review_batch!(target, batch, apply_review)
    |> Enum.each(
      &finalize_review_result!(root, target, apply_review, skip_stale, &1, started_branch)
    )
  end

  def current_branch!(root) do
    Git.current_branch!(root)
  end

  def git_head(root) do
    Git.head(root)
  end

  def changed_path_set(root) do
    Git.changed_path_set(root)
  end

  def ensure_head_unchanged!(root, baseline_head, relative_review) do
    current_head = git_head(root)

    unless current_head == baseline_head do
      abort(
        "Codex changed HEAD while applying #{relative_review}; commits must be created by this script"
      )
    end
  end

  def expose_new_untracked_files_to_diff!(root, baseline_paths, relative_review) do
    new_untracked_paths =
      root
      |> changed_path_set()
      |> MapSet.difference(baseline_paths)
      |> MapSet.intersection(Git.untracked_path_set(root))
      |> MapSet.to_list()
      |> Enum.sort()

    if new_untracked_paths != [] do
      Git.run!(
        root,
        ["add", "-N", "--" | new_untracked_paths],
        "mark new files for fix review of #{relative_review}"
      )
    end
  end

  def discard_new_changes!(root, baseline_paths, relative_review) do
    new_paths =
      root
      |> changed_path_set()
      |> MapSet.difference(baseline_paths)
      |> MapSet.to_list()
      |> Enum.sort_by(&discard_order/1, :desc)

    Enum.each(new_paths, &discard_new_path!(root, &1, relative_review))
  end

  def commit_paths(root, baseline_paths, always_include_paths) do
    changed_paths = changed_path_set(root)

    changed_paths
    |> MapSet.difference(baseline_paths)
    |> MapSet.union(MapSet.intersection(changed_paths, MapSet.new(always_include_paths)))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  def commit_review_changes!([], _root, relative_review, _commit_message_fun) do
    IO.puts(
      "No new committable changes found after applying #{relative_review}; treating as already applied"
    )
  end

  def commit_review_changes!(paths, root, relative_review, commit_message_fun) do
    commit_message = commit_message_fun.()
    stage_paths = stageable_paths(root, paths)

    if stage_paths != [] do
      Git.run!(root, ["add", "-A", "--" | stage_paths], "stage changes for #{relative_review}")
    end

    ensure_only_expected_staged_paths!(root, MapSet.new(paths), relative_review)
    ensure_staged_changes!(root, relative_review)
    Git.run!(root, ["commit", "-m", commit_message], "commit changes for #{relative_review}")
    IO.puts("Committed #{relative_review}: #{commit_message}")
  end

  defp ensure_clean_working_tree_except_reviews!(root, target) do
    paths =
      root
      |> changed_path_set()
      |> MapSet.to_list()
      |> Enum.reject(&under_review_target?(root, target, &1))
      |> Enum.sort()

    unless paths == [] do
      dirty =
        paths
        |> Enum.map_join("\n", &("- " <> &1))

      abort("""
      Refusing to run with local non-review changes.

      The apply script creates commits directly in this checkout.
      Commit, stash, or move these files before running:
      #{dirty}
      """)
    end
  end

  defp under_review_target?(root, target, path) do
    relative_target = Path.relative_to(target, root)

    cond do
      relative_target == "." ->
        false

      File.dir?(target) ->
        path == relative_target or String.starts_with?(path, relative_target <> "/")

      true ->
        path == relative_target
    end
  end

  defp apply_review_batch!(root, target, [job], apply_review) do
    [
      %{
        mode: :current,
        status: apply_review.(root, target, job.review_path),
        job: job
      }
    ]
  end

  defp apply_review_batch!(root, target, batch, apply_review) do
    base_head = git_head(root)

    stream =
      batch
      |> Task.async_stream(
        &Worktree.apply!(root, target, &1, base_head, apply_review),
        max_concurrency: length(batch),
        ordered: true,
        timeout: :infinity
      )

    batch
    |> Enum.zip(stream)
    |> Enum.map(fn
      {_job, {:ok, result}} ->
        result

      {job, {:exit, reason}} ->
        %{
          mode: :worktree,
          status: :failed,
          job: job,
          branch: nil,
          worktree: nil,
          error: "Review application task exited: #{inspect(reason)}"
        }
    end)
  end

  defp finalize_review_result!(
         _root,
         _target,
         _apply_review,
         _skip_stale,
         %{mode: :current},
         _started_branch
       ),
       do: :ok

  defp finalize_review_result!(
         root,
         target,
         apply_review,
         _skip_stale,
         %{mode: :worktree, status: :approved, job: job, branch: branch} = result,
         started_branch
       ) do
    merge_result =
      try do
        ensure_on_started_branch!(root, started_branch)

        case merge_review_branch(root, job.relative_review, branch) do
          :ok ->
            delete_original_review_after_merge!(job.review_path)
            :ok

          {:retry_sequential, output} ->
            {:retry_sequential, output}
        end
      after
        Worktree.cleanup!(root, result)
      end

    case merge_result do
      :ok ->
        :ok

      {:retry_sequential, output} ->
        retry_review_sequential_after_merge_conflict!(root, target, apply_review, job, output)
    end
  end

  defp finalize_review_result!(
         root,
         _target,
         _apply_review,
         skip_stale,
         %{mode: :worktree, status: :skipped_stale, job: job} = result,
         _started_branch
       ) do
    try do
      skip_stale.(root, job)
    after
      Worktree.cleanup!(root, result)
    end
  end

  defp finalize_review_result!(
         root,
         _target,
         _apply_review,
         _skip_stale,
         %{mode: :worktree, status: :failed, job: job, error: error} = result,
         _started_branch
       ) do
    try do
      abort("Failed applying #{job.relative_review}: #{error}")
    after
      Worktree.cleanup!(root, result)
    end
  end

  defp finalize_review_result!(
         root,
         _target,
         _apply_review,
         _skip_stale,
         %{mode: :worktree} = result,
         _started_branch
       ) do
    Worktree.cleanup!(root, result)
  end

  defp retry_review_sequential_after_merge_conflict!(root, target, apply_review, job, output) do
    IO.puts(
      "Retrying #{job.relative_review} sequentially from current branch head after missed merge conflict"
    )

    IO.puts("The failed parallel merge was aborted before retrying.")
    print_command_output(output)

    case apply_review.(root, target, job.review_path) do
      :approved -> :ok
      :deferred -> :ok
    end
  end

  defp merge_review_branch(root, relative_review, branch) do
    IO.puts("Merging #{relative_review} from #{branch}")

    case System.cmd("git", ["merge", "--no-ff", "--no-edit", branch],
           cd: root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        print_command_output(output)
        :ok

      {output, _status} ->
        print_command_output(output)

        if Git.merge_in_progress?(root) do
          Git.run!(root, ["merge", "--abort"], "abort conflicted merge")
          {:retry_sequential, output}
        else
          abort("Failed merging #{relative_review} from #{branch}:\n#{output}")
        end
    end
  end

  defp print_command_output(""), do: :ok
  defp print_command_output(output), do: IO.puts(output)

  defp delete_original_review_after_merge!(review_path) do
    case File.rm(review_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> abort("Failed deleting original review after merge: #{inspect(reason)}")
    end
  end

  defp ensure_on_started_branch!(root, started_branch) do
    current_branch = current_branch!(root)

    unless current_branch == started_branch do
      abort("Expected to merge into #{started_branch}, but current branch is #{current_branch}")
    end
  end

  defp discard_order(path), do: length(Path.split(path))

  defp discard_new_path!(root, path, relative_review) do
    if Git.tracked_in_head?(root, path) do
      Git.run!(
        root,
        ["restore", "--staged", "--worktree", "--", path],
        "discard failed changes for #{relative_review}"
      )
    else
      Git.run!(
        root,
        ["rm", "--cached", "--ignore-unmatch", "-r", "--", path],
        "unstage failed untracked changes for #{relative_review}"
      )

      root
      |> Path.join(path)
      |> File.rm_rf()
    end
  end

  defp stageable_paths(root, paths) do
    paths
    |> Enum.filter(fn path ->
      File.exists?(Path.join(root, path)) or Git.tracked_in_head?(root, path)
    end)
  end

  defp ensure_no_staged_changes!(root) do
    staged_paths = Git.staged_path_set(root)

    unless MapSet.size(staged_paths) == 0 do
      staged =
        staged_paths
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.map_join("\n", &("- " <> &1))

      abort("Refusing to run with pre-staged changes:\n#{staged}")
    end
  end

  defp ensure_only_expected_staged_paths!(root, expected_paths, relative_review) do
    unexpected_paths =
      root
      |> Git.staged_path_set()
      |> MapSet.difference(expected_paths)

    unless MapSet.size(unexpected_paths) == 0 do
      unexpected =
        unexpected_paths
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.map_join("\n", &("- " <> &1))

      abort("Unexpected staged paths while applying #{relative_review}:\n#{unexpected}")
    end
  end

  defp ensure_staged_changes!(root, relative_review) do
    if Git.staged_changes?(root) do
      :ok
    else
      abort("No staged changes found while applying #{relative_review}")
    end
  end

  defp abort(message) do
    raise Review.Error, message
  end
end
