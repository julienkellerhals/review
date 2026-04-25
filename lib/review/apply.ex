defmodule Review.Apply do
  alias Review.SourcePolicy
  @default_model "gpt-5.5"
  @default_reasoning_effort "medium"
  @default_max_fix_attempts 3
  @default_codex_command_max_attempts 3
  @default_apply_concurrency 10
  @fix_approved "FIX_APPROVED"
  @deferred_review_start "<!-- apply-review-deferred-start -->"
  @deferred_review_end "<!-- apply-review-deferred-end -->"
  @source_file_pattern ~r/^Source file:\s+(.+?)$/

  def main(["-h"]), do: usage()
  def main(["--help"]), do: usage()

  def main(args) do
    root = repo_root()
    target = review_target(root, args)
    source_blacklist = SourcePolicy.source_blacklist()
    reviews = review_files(target)
    ensure_no_staged_changes!(root)
    ensure_clean_working_tree_except_reviews!(root, target)

    apply_reviews!(root, target, source_blacklist, reviews)
  end

  defp usage do
    IO.puts("Usage: mix review.apply [review|path/to/review.md]")

    IO.puts("Set REVIEW_DIR to change the default review directory.")

    IO.puts(
      "Set REVIEW_SOURCE_BLACKLIST to comma-separated source folder names to exclude. Bare names and **/name/ both match any path segment."
    )

    IO.puts("Set CODEX_MODEL to override the Codex model. Defaults to gpt-5.5.")

    IO.puts("Set CODEX_REASONING_EFFORT to override the reasoning effort. Defaults to medium.")

    IO.puts("Set CODEX_FIX_REVIEW_MAX_ATTEMPTS to override fix-review retries. Defaults to 3.")

    IO.puts(
      "Set CODEX_COMMAND_MAX_ATTEMPTS to retry retryable Codex command failures. Defaults to 3."
    )

    IO.puts("Set CODEX_APPLY_CONCURRENCY to cap parallel implementation agents. Defaults to 10.")

    IO.puts(
      "Approved reviews are deleted, staged, and committed. Exhausted reviews are annotated and left for a later run."
    )

    IO.puts("The starting checkout must be clean except for files under the review target.")
  end

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> root |> String.trim() |> Path.expand()
      _ -> File.cwd!()
    end
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

  defp apply_reviews!(root, target, source_blacklist, reviews) do
    jobs =
      reviews
      |> Enum.flat_map(fn review_path ->
        case review_job(root, target, source_blacklist, review_path) do
          {:ok, job} -> [job]
          :skipped_stale -> []
        end
      end)

    if jobs == [] do
      IO.puts("No applicable reviews left after skipping stale review files")
      :ok
    else
      apply_review_jobs!(root, target, source_blacklist, jobs)
    end
  end

  defp apply_review_jobs!(root, target, source_blacklist, jobs) do
    concurrency = apply_concurrency()
    batches = plan_review_batches(jobs, concurrency)

    IO.puts(
      "Implementation plan: #{length(jobs)} review(s), #{length(batches)} batch(es), up to #{concurrency} parallel agent(s)"
    )

    started_branch = current_branch!(root)
    total_batches = length(batches)

    batches
    |> Enum.with_index(1)
    |> Enum.each(fn {batch, index} ->
      parallel_agents = min(length(batch), concurrency)

      IO.puts(
        "Batch #{index}/#{total_batches}: applying #{length(batch)} review(s) with #{parallel_agents} parallel agent(s)"
      )

      Enum.each(batch, fn job ->
        IO.puts("- #{job.relative_review} affects: #{Enum.join(job.affected_files, ", ")}")
      end)

      root
      |> apply_review_batch!(target, source_blacklist, batch)
      |> Enum.each(&finalize_review_result!(root, target, source_blacklist, &1, started_branch))

      IO.puts("Remaining implementation steps after this batch: #{total_batches - index}")
    end)
  end

  defp review_job(root, target, source_blacklist, review_path) do
    relative_review = Path.relative_to(review_path, root)
    source_file = source_from_review(root, review_path, target)

    case validate_source_file(root, source_blacklist, relative_review, source_file) do
      :ok ->
        affected_files =
          review_path
          |> affected_files_from_review()
          |> then(&[source_file | &1])
          |> Enum.map(&normalize_affected_path(root, &1))
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.sort()

        {:ok,
         %{
           review_path: review_path,
           relative_review: relative_review,
           source_file: source_file,
           affected_files: affected_files
         }}

      {:stale, message} ->
        skip_stale_review!(root, review_path, relative_review, source_file, message)
        :skipped_stale
    end
  end

  defp affected_files_from_review(review_path) do
    review_path
    |> File.stream!()
    |> Enum.reduce_while({:searching, []}, fn line, {mode, files} ->
      trimmed = String.trim(line)

      cond do
        mode == :searching and trimmed == "Affected files:" ->
          {:cont, {:collecting, files}}

        mode == :searching and String.starts_with?(trimmed, "Affected files:") ->
          {:halt,
           {:error,
            "Malformed affected files metadata in #{review_path}: expected `Affected files:` on its own line followed by repo-relative bullet items"}}

        mode == :searching ->
          {:cont, {mode, files}}

        mode == :collecting and trimmed == "" and files != [] ->
          {:halt, {:done, files}}

        mode == :collecting and trimmed == "" ->
          {:halt,
           {:error,
            "Malformed affected files metadata in #{review_path}: expected repo-relative bullet items after `Affected files:`"}}

        mode == :collecting and String.starts_with?(trimmed, "- ") ->
          path = trimmed |> String.trim_leading("- ") |> clean_metadata_path()

          cond do
            path == "" ->
              {:halt,
               {:error,
                "Malformed affected files metadata in #{review_path}: empty bullet item under `Affected files:`"}}

            true ->
              {:cont, {:collecting, files ++ [path]}}
          end

        mode == :collecting and String.starts_with?(trimmed, "#") and files != [] ->
          {:halt, {:done, files}}

        mode == :collecting ->
          {:halt,
           {:error,
            "Malformed affected files metadata in #{review_path}: expected repo-relative bullet items after `Affected files:`"}}
      end
    end)
    |> case do
      {:done, files} ->
        files

      {:searching, files} ->
        files

      {:collecting, []} ->
        abort(
          "Malformed affected files metadata in #{review_path}: expected repo-relative bullet items after `Affected files:`"
        )

      {:collecting, files} ->
        files

      {:error, message} ->
        abort(message)
    end
  end

  defp clean_metadata_path(path) do
    path
    |> String.trim()
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
    |> String.trim()
  end

  defp normalize_affected_path(root, path) do
    path =
      path
      |> String.trim()
      |> String.trim_leading("./")

    expanded = Path.expand(path, root)

    if under_repo_root?(root, expanded) do
      Path.relative_to(expanded, root)
    else
      path
    end
  end

  def plan_review_batches(jobs, concurrency) do
    jobs
    |> do_plan_review_batches(concurrency, [])
    |> Enum.reverse()
  end

  defp do_plan_review_batches([], _concurrency, batches), do: batches

  defp do_plan_review_batches(jobs, concurrency, batches) do
    {batch, remaining} = take_non_conflicting_batch(jobs, concurrency)
    do_plan_review_batches(remaining, concurrency, [batch | batches])
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

  defp apply_review_batch!(root, target, source_blacklist, [job]) do
    [
      %{
        mode: :current,
        status: apply_review(root, target, source_blacklist, job.review_path),
        job: job
      }
    ]
  end

  defp apply_review_batch!(root, target, source_blacklist, batch) do
    base_head = git_head(root)

    stream =
      batch
      |> Task.async_stream(
        &apply_review_in_worktree!(root, target, source_blacklist, &1, base_head),
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

  defp apply_review_in_worktree!(root, target, source_blacklist, job, base_head) do
    branch = worktree_branch_name(job.relative_review)
    worktree = worktree_path(root, job.relative_review)

    try do
      IO.puts("Starting #{job.relative_review} in #{worktree}")
      run_git!(root, ["worktree", "add", "-b", branch, worktree, base_head], "create worktree")
      sync_current_checkout_to_worktree!(root, worktree)
      copy_review_to_worktree!(root, worktree, job.relative_review)

      worktree_target =
        target
        |> Path.relative_to(root)
        |> then(&Path.join(worktree, &1))

      worktree_review = Path.join(worktree, job.relative_review)
      status = apply_review(worktree, worktree_target, source_blacklist, worktree_review)

      if status == :deferred and File.exists?(worktree_review) do
        File.mkdir_p!(Path.dirname(job.review_path))
        File.cp!(worktree_review, job.review_path)
      end

      %{
        mode: :worktree,
        status: status,
        job: job,
        branch: branch,
        worktree: worktree
      }
    rescue
      exception ->
        %{
          mode: :worktree,
          status: :failed,
          job: job,
          branch: branch,
          worktree: worktree,
          error: Exception.message(exception)
        }
    catch
      kind, reason ->
        %{
          mode: :worktree,
          status: :failed,
          job: job,
          branch: branch,
          worktree: worktree,
          error: "#{kind} #{inspect(reason)}"
        }
    end
  end

  defp positive_integer_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 ->
            integer

          _ ->
            abort("Expected #{name} to be a positive integer, got: #{inspect(value)}")
        end
    end
  end

  defp apply_concurrency do
    positive_integer_env("CODEX_APPLY_CONCURRENCY", @default_apply_concurrency)
  end

  defp finalize_review_result!(
         _root,
         _target,
         _source_blacklist,
         %{mode: :current},
         _started_branch
       ),
       do: :ok

  defp finalize_review_result!(
         root,
         target,
         source_blacklist,
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
        cleanup_worktree_and_branch!(root, result)
      end

    case merge_result do
      :ok ->
        :ok

      {:retry_sequential, output} ->
        retry_review_sequential_after_merge_conflict!(
          root,
          target,
          source_blacklist,
          job,
          output
        )
    end
  end

  defp finalize_review_result!(
         root,
         _target,
         _source_blacklist,
         %{mode: :worktree, status: :skipped_stale, job: job} = result,
         _started_branch
       ) do
    try do
      skip_stale_review!(
        root,
        job.review_path,
        job.relative_review,
        job.source_file,
        stale_source_message(job.relative_review, job.source_file)
      )
    after
      cleanup_worktree_and_branch!(root, result)
    end
  end

  defp finalize_review_result!(
         root,
         _target,
         _source_blacklist,
         %{mode: :worktree, status: :failed, job: job, error: error} = result,
         _started_branch
       ) do
    try do
      abort("Failed applying #{job.relative_review}: #{error}")
    after
      cleanup_worktree_and_branch!(root, result)
    end
  end

  defp finalize_review_result!(
         root,
         _target,
         _source_blacklist,
         %{mode: :worktree} = result,
         _started_branch
       ) do
    cleanup_worktree_and_branch!(root, result)
  end

  defp retry_review_sequential_after_merge_conflict!(
         root,
         target,
         source_blacklist,
         job,
         merge_output
       ) do
    IO.puts(
      "Retrying #{job.relative_review} sequentially from current branch head after missed merge conflict"
    )

    IO.puts("The failed parallel merge was aborted before retrying.")
    print_command_output(merge_output)

    case apply_review(root, target, source_blacklist, job.review_path) do
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

        if merge_in_progress?(root) do
          run_git!(root, ["merge", "--abort"], "abort conflicted merge")
          {:retry_sequential, output}
        else
          abort("Failed merging #{relative_review} from #{branch}:\n#{output}")
        end
    end
  end

  defp print_command_output(""), do: :ok
  defp print_command_output(output), do: IO.puts(output)

  defp merge_in_progress?(root) do
    case System.cmd("git", ["rev-parse", "-q", "--verify", "MERGE_HEAD"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

  defp delete_original_review_after_merge!(review_path) do
    case File.rm(review_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> abort("Failed deleting original review after merge: #{inspect(reason)}")
    end
  end

  defp cleanup_worktree_and_branch!(root, %{worktree: worktree, branch: branch}) do
    if is_binary(worktree) do
      System.cmd("git", ["worktree", "remove", "--force", worktree],
        cd: root,
        stderr_to_stdout: true
      )
    end

    if is_binary(branch) do
      System.cmd("git", ["branch", "-D", branch], cd: root, stderr_to_stdout: true)
    end
  end

  defp current_branch!(root) do
    case System.cmd("git", ["symbolic-ref", "--quiet", "--short", "HEAD"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {branch, 0} ->
        String.trim(branch)

      {output, _status} ->
        abort("Expected to start on a branch, but HEAD is detached:\n#{output}")
    end
  end

  defp ensure_on_started_branch!(root, started_branch) do
    current_branch = current_branch!(root)

    unless current_branch == started_branch do
      abort("Expected to merge into #{started_branch}, but current branch is #{current_branch}")
    end
  end

  defp worktree_branch_name(relative_review) do
    suffix = unique_worktree_suffix()

    review_slug =
      relative_review
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    "apply-review/#{review_slug}-#{suffix}"
  end

  defp worktree_path(root, relative_review) do
    review_slug =
      relative_review
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    Path.join(
      git_common_dir!(root),
      "apply-review-worktrees/#{review_slug}-#{unique_worktree_suffix()}"
    )
  end

  defp git_common_dir!(root) do
    root
    |> git_output!(["rev-parse", "--git-common-dir"], "read git common directory")
    |> String.trim()
    |> Path.expand(root)
  end

  defp unique_worktree_suffix do
    "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp sync_current_checkout_to_worktree!(root, worktree) do
    root_entries = checkout_entries!(root)
    worktree_entries = checkout_entries!(worktree)

    worktree_entries
    |> MapSet.difference(root_entries)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.each(fn entry ->
      remove_checkout_path!(Path.join(worktree, entry), "remove stale worktree path")
    end)

    root_entries
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.each(fn entry ->
      source = Path.join(root, entry)
      destination = Path.join(worktree, entry)

      remove_checkout_path!(destination, "replace worktree path")
      copy_checkout_path!(source, destination)
    end)
  end

  defp checkout_entries!(path) do
    path
    |> File.ls!()
    |> Enum.reject(&(&1 == ".git"))
    |> MapSet.new()
  end

  defp remove_checkout_path!(path, _context) do
    case File.rm_rf(path) do
      {:ok, _removed_paths} ->
        :ok

      {:error, reason, failed_path} ->
        abort("Failed removing #{failed_path} while syncing worktree: #{inspect(reason)}")
    end
  end

  defp copy_checkout_path!(source, destination) do
    case File.cp_r(source, destination) do
      {:ok, _copied_paths} ->
        :ok

      {:error, reason, failed_path} ->
        abort("Failed copying #{failed_path} into #{destination}: #{inspect(reason)}")
    end
  end

  defp copy_review_to_worktree!(root, worktree, relative_review) do
    source = Path.join(root, relative_review)
    destination = Path.join(worktree, relative_review)

    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
  end

  defp review_target(root, []) do
    Review.Config.review_dir(root)
  end

  defp review_target(root, [target | _rest]), do: Path.expand(target, root)

  defp review_files(target) do
    cond do
      File.regular?(target) ->
        [target]

      File.dir?(target) ->
        reviews =
          target
          |> collect_review_files()
          |> Enum.sort()

        if reviews == [] do
          IO.puts("No review.md files found under #{target}")
          []
        else
          reviews
        end

      true ->
        abort("Expected a review directory or review.md file, got: #{target}")
    end
  end

  defp collect_review_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) -> collect_review_files(path)
        File.regular?(path) and Path.basename(path) == "review.md" -> [Path.expand(path)]
        true -> []
      end
    end)
  end

  defp apply_review(root, target, source_blacklist, review_path) do
    relative_review = Path.relative_to(review_path, root)
    source_file = source_from_review(root, review_path, target)
    baseline_head = git_head(root)
    baseline_paths = changed_path_set(root)

    case validate_source_file(root, source_blacklist, relative_review, source_file) do
      :ok ->
        max_attempts = max_fix_attempts()

        case apply_until_review_approved!(
               root,
               relative_review,
               source_file,
               baseline_head,
               max_attempts
             ) do
          :approved ->
            delete_review!(review_path, relative_review)

            paths = commit_paths(root, baseline_paths, [relative_review])

            commit_review_changes!(
              paths,
              root,
              relative_review,
              fn -> generate_commit_message!(root, relative_review, source_file) end
            )

            :approved

          {:deferred, rejection} ->
            defer_rejected_review!(
              root,
              review_path,
              relative_review,
              rejection,
              max_attempts,
              baseline_paths
            )

            :deferred
        end

      {:stale, message} ->
        skip_stale_review!(root, review_path, relative_review, source_file, message)
        :skipped_stale
    end
  end

  defp source_from_review(root, review_path, target) do
    review_path
    |> File.stream!()
    |> Enum.find_value("", fn line ->
      case Regex.run(@source_file_pattern, String.trim(line)) do
        [_line, source_file] -> clean_metadata_path(source_file)
        _ -> nil
      end
    end)
    |> fallback_source_from_path(root, review_path, target)
  end

  defp fallback_source_from_path("", root, review_path, target) do
    target_dir =
      if File.dir?(target) do
        target
      else
        Review.Config.review_dir(root)
      end

    relative_review = Path.relative_to(review_path, target_dir)

    if String.ends_with?(relative_review, "/review.md") do
      String.replace_suffix(relative_review, "/review.md", "")
    else
      ""
    end
  end

  defp fallback_source_from_path(source_file, _root, _review_path, _target), do: source_file

  defp validate_source_file(root, source_blacklist, relative_review, source_file) do
    absolute_source = Path.expand(source_file, root)

    if source_file == "" do
      abort("Could not infer source file for #{relative_review}")
    end

    unless under_repo_root?(root, absolute_source) do
      abort("Expected source file under #{root} for #{relative_review}: #{source_file}")
    end

    if SourcePolicy.blacklisted_path?(root, absolute_source, source_blacklist) do
      abort(
        "Source file is under a blacklisted folder (#{SourcePolicy.format_source_blacklist(source_blacklist)}) for #{relative_review}: #{source_file}"
      )
    end

    if File.regular?(absolute_source) and SourcePolicy.source_file_extension?(absolute_source) do
      :ok
    else
      {:stale, stale_source_message(relative_review, source_file)}
    end
  end

  defp stale_source_message(relative_review, source_file) do
    "Source file no longer exists or has an unsupported extension for #{relative_review}: #{source_file}"
  end

  defp skip_stale_review!(root, review_path, relative_review, source_file, message) do
    baseline_paths = changed_path_set(root)
    IO.puts("Skipping stale review #{relative_review}: #{source_file}")
    IO.puts(message)
    delete_review!(review_path, relative_review)

    paths = commit_paths(root, baseline_paths, [relative_review])

    commit_review_changes!(paths, root, relative_review, fn ->
      "Remove stale review"
    end)
  end

  defp under_repo_root?(root, source) do
    source == root or String.starts_with?(source, root <> "/")
  end

  defp codex_apply_args(root) do
    [
      "exec",
      "--cd",
      root,
      "--full-auto",
      "-"
    ]
    |> add_codex_runtime_options()
  end

  defp codex_read_only_args(root, output_path) do
    [
      "exec",
      "--cd",
      root,
      "--sandbox",
      "read-only",
      "--output-last-message",
      output_path,
      "-"
    ]
    |> add_codex_runtime_options()
  end

  defp add_codex_runtime_options(args) do
    [
      "--config",
      "model_reasoning_effort=#{codex_reasoning_effort()}",
      "--model",
      codex_model()
      | args
    ]
  end

  defp codex_model do
    env_or_default("CODEX_MODEL", @default_model)
  end

  defp codex_reasoning_effort do
    env_or_default("CODEX_REASONING_EFFORT", @default_reasoning_effort)
  end

  defp max_fix_attempts do
    positive_integer_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS", @default_max_fix_attempts)
  end

  defp codex_command_max_attempts do
    positive_integer_env("CODEX_COMMAND_MAX_ATTEMPTS", @default_codex_command_max_attempts)
  end

  defp env_or_default(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  defp run_codex(args, prompt) do
    prompt_path = tmp_path("codex-review-apply-prompt", "md")

    File.write!(prompt_path, prompt)

    try do
      run_codex_with_retry(args, prompt_path, codex_command_max_attempts(), 1)
    after
      File.rm(prompt_path)
    end
  end

  defp run_codex_with_retry(args, prompt_path, max_attempts, attempt) do
    log_path = tmp_path("codex-review-apply", "log")

    command =
      (["codex" | args] |> Enum.map_join(" ", &shell_quote/1)) <>
        " < " <>
        shell_quote(prompt_path) <>
        " > " <> shell_quote(log_path) <> " 2>&1"

    result = System.cmd("sh", ["-c", command])
    log = read_log(log_path)

    File.rm(log_path)

    case result do
      {_, 0} ->
        result

      {_, _status} when attempt < max_attempts ->
        if retryable_codex_failure?(log) do
          maybe_report_failed_log(result, log)

          IO.puts(
            :stderr,
            "Retrying Codex command after retryable failure (attempt #{attempt + 1}/#{max_attempts})"
          )

          run_codex_with_retry(args, prompt_path, max_attempts, attempt + 1)
        else
          maybe_report_failed_log(result, log)
          result
        end

      {_, _status} ->
        maybe_report_failed_log(result, log)
        result
    end
  end

  defp read_log(log_path) do
    case File.read(log_path) do
      {:ok, log} -> log
      {:error, _reason} -> ""
    end
  end

  defp maybe_report_failed_log({_output, 0}, _log), do: :ok

  defp maybe_report_failed_log({_output, _status}, log) do
    IO.puts(:stderr, "Codex log:")
    IO.puts(:stderr, log)
  end

  defp retryable_codex_failure?(log) do
    normalized = String.downcase(log)

    Enum.any?(
      [
        "context_length_exceeded",
        "compact_remote",
        "error running remote compact task",
        "input exceeds the context window",
        "remote compaction failed"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp apply_until_review_approved!(
         root,
         relative_review,
         source_file,
         baseline_head,
         max_attempts
       ) do
    1..max_attempts
    |> Enum.reduce_while(nil, fn attempt, previous_rejection ->
      if attempt == 1 do
        IO.puts("Applying #{relative_review}")
      else
        IO.puts("Re-applying #{relative_review} after fix review rejection")
      end

      prompt = apply_prompt(relative_review, source_file, previous_rejection)

      case run_codex(codex_apply_args(root), prompt) do
        {_, 0} -> :ok
        {_, status} -> abort("Failed applying #{relative_review}; codex exited with #{status}")
      end

      ensure_head_unchanged!(root, baseline_head, relative_review)

      case review_fix_result!(root, relative_review, source_file) do
        :approved ->
          {:halt, :approved}

        {:rejected, rejection} when attempt == max_attempts ->
          IO.puts(
            :stderr,
            "Fix review rejected for #{relative_review} after #{max_attempts} attempt(s):\n#{rejection}"
          )

          {:halt, {:deferred, rejection}}

        {:rejected, rejection} ->
          IO.puts(:stderr, "Fix review rejected for #{relative_review}:\n#{rejection}")
          {:cont, rejection}
      end
    end)
  end

  defp review_fix_result!(root, relative_review, source_file) do
    output_path = tmp_markdown_path("codex-fix-review")

    IO.puts("Reviewing fix against #{relative_review}")

    case run_codex(
           codex_read_only_args(root, output_path),
           review_fix_prompt(relative_review, source_file)
         ) do
      {_, 0} ->
        output = read_and_remove(output_path)

        if String.trim(output) == @fix_approved do
          :approved
        else
          {:rejected, output}
        end

      {_, status} ->
        File.rm(output_path)
        abort("Failed reviewing fix for #{relative_review}; codex exited with #{status}")
    end
  end

  defp defer_rejected_review!(
         root,
         review_path,
         relative_review,
         rejection,
         max_attempts,
         baseline_paths
       ) do
    IO.puts(
      "Deferring #{relative_review} after #{max_attempts} rejected attempt(s); recording review feedback and continuing"
    )

    discard_new_changes!(root, baseline_paths, relative_review)
    write_deferred_review!(review_path, relative_review, rejection, max_attempts)
  end

  defp discard_new_changes!(root, baseline_paths, relative_review) do
    new_paths =
      root
      |> changed_path_set()
      |> MapSet.difference(baseline_paths)
      |> MapSet.to_list()
      |> Enum.sort_by(&discard_order/1, :desc)

    Enum.each(new_paths, &discard_new_path!(root, &1, relative_review))
  end

  defp discard_order(path), do: length(Path.split(path))

  defp discard_new_path!(root, path, relative_review) do
    if tracked_in_head?(root, path) do
      run_git!(
        root,
        ["restore", "--staged", "--worktree", "--", path],
        "discard failed changes for #{relative_review}"
      )
    else
      run_git!(
        root,
        ["rm", "--cached", "--ignore-unmatch", "-r", "--", path],
        "unstage failed untracked changes for #{relative_review}"
      )

      root
      |> Path.join(path)
      |> File.rm_rf()
    end
  end

  defp tracked_in_head?(root, path) do
    root
    |> git_output!(["ls-tree", "-r", "--name-only", "HEAD", "--", path], "inspect HEAD")
    |> String.split("\n", trim: true)
    |> Enum.member?(path)
  end

  defp write_deferred_review!(review_path, relative_review, rejection, max_attempts) do
    content = File.read!(review_path)
    section = deferred_review_section(rejection, max_attempts)

    updated =
      if String.contains?(content, @deferred_review_start) do
        pattern =
          Regex.compile!(
            Regex.escape(@deferred_review_start) <> ".*" <> Regex.escape(@deferred_review_end),
            "s"
          )

        Regex.replace(pattern, content, section)
      else
        String.trim_trailing(content) <> "\n\n" <> section
      end

    File.write!(review_path, updated)
    IO.puts("Updated #{relative_review} with latest failed fix review output")
  end

  defp deferred_review_section(rejection, max_attempts) do
    """
    #{@deferred_review_start}
    ## Latest Failed Apply Attempt

    The apply script tried #{max_attempts} time(s). The read-only fix review still rejected the result, so this review was deferred and the failed working-tree changes were discarded.

    Reviewer output:

    ```text
    #{escape_markdown_fence(String.trim(rejection))}
    ```
    #{@deferred_review_end}
    """
  end

  defp escape_markdown_fence(content) do
    String.replace(content, "```", "'''")
  end

  defp generate_commit_message!(root, relative_review, source_file) do
    output_path = tmp_markdown_path("codex-review-commit-message")

    IO.puts("Generating commit message for #{relative_review}")

    case run_codex(
           codex_read_only_args(root, output_path),
           commit_message_prompt(relative_review, source_file)
         ) do
      {_, 0} ->
        output_path
        |> read_and_remove()
        |> commit_subject!()

      {_, status} ->
        File.rm(output_path)

        abort(
          "Failed generating commit message for #{relative_review}; codex exited with #{status}"
        )
    end
  end

  defp tmp_markdown_path(prefix) do
    tmp_path(prefix, "md")
  end

  defp tmp_path(prefix, extension) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.#{extension}")
  end

  defp read_and_remove(path) do
    content =
      case File.read(path) do
        {:ok, content} -> content
        {:error, _reason} -> ""
      end

    File.rm(path)
    content
  end

  defp commit_subject!(content) do
    subject =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "```")))
      |> List.first()

    if subject in [nil, ""] do
      abort("Codex did not generate a usable commit message")
    end

    subject
  end

  defp delete_review!(review_path, relative_review) do
    case File.rm(review_path) do
      :ok ->
        IO.puts("Deleted #{relative_review}")

      {:error, :enoent} ->
        abort("Review file was already deleted before script cleanup: #{relative_review}")

      {:error, reason} ->
        abort("Failed deleting #{relative_review}: #{inspect(reason)}")
    end
  end

  defp commit_paths(root, baseline_paths, always_include_paths) do
    changed_paths = changed_path_set(root)

    changed_paths
    |> MapSet.difference(baseline_paths)
    |> MapSet.union(MapSet.intersection(changed_paths, MapSet.new(always_include_paths)))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp commit_review_changes!([], _root, relative_review, _commit_message_fun) do
    IO.puts(
      "No new committable changes found after applying #{relative_review}; treating as already applied"
    )
  end

  defp commit_review_changes!(paths, root, relative_review, commit_message_fun) do
    commit_message = commit_message_fun.()
    stage_paths = stageable_paths(root, paths)

    if stage_paths != [] do
      run_git!(root, ["add", "-A", "--" | stage_paths], "stage changes for #{relative_review}")
    end

    ensure_only_expected_staged_paths!(root, MapSet.new(paths), relative_review)
    ensure_staged_changes!(root, relative_review)
    run_git!(root, ["commit", "-m", commit_message], "commit changes for #{relative_review}")
    IO.puts("Committed #{relative_review}: #{commit_message}")
  end

  defp stageable_paths(root, paths) do
    paths
    |> Enum.filter(fn path ->
      File.exists?(Path.join(root, path)) or tracked_in_head?(root, path)
    end)
  end

  defp ensure_no_staged_changes!(root) do
    staged_paths = staged_path_set(root)

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
      |> staged_path_set()
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
    case System.cmd("git", ["diff", "--cached", "--quiet", "--exit-code"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        abort("No staged changes found while applying #{relative_review}")

      {_, 1} ->
        :ok

      {output, status} ->
        abort("Failed checking staged changes; git exited with #{status}:\n#{output}")
    end
  end

  defp ensure_head_unchanged!(root, baseline_head, relative_review) do
    current_head = git_head(root)

    unless current_head == baseline_head do
      abort(
        "Codex changed HEAD while applying #{relative_review}; commits must be created by this script"
      )
    end
  end

  defp git_head(root) do
    root
    |> git_output!(["rev-parse", "HEAD"], "read HEAD")
    |> String.trim()
  end

  defp changed_path_set(root) do
    root
    |> git_output!(["status", "--porcelain=v1", "-z", "--untracked-files=all"], "read git status")
    |> parse_status_entries()
    |> MapSet.new()
  end

  defp staged_path_set(root) do
    root
    |> git_output!(["diff", "--cached", "--name-only", "-z"], "read staged paths")
    |> String.split(<<0>>, trim: true)
    |> MapSet.new()
  end

  defp parse_status_entries(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> parse_status_entries([])
  end

  defp parse_status_entries([], paths), do: paths

  defp parse_status_entries([entry | rest], paths) do
    path = status_entry_path(entry)
    paths = [path | paths]

    if rename_or_copy_status?(entry) and rest != [] do
      [previous_path | rest] = rest
      parse_status_entries(rest, [previous_path | paths])
    else
      parse_status_entries(rest, paths)
    end
  end

  defp status_entry_path(<<_status::binary-size(2), " ", path::binary>>), do: path
  defp status_entry_path(path), do: path

  defp rename_or_copy_status?(<<index_status, unstaged_status, " ", _path::binary>>) do
    index_status in [?R, ?C] or unstaged_status in [?R, ?C]
  end

  defp rename_or_copy_status?(_entry), do: false

  defp git_output!(root, args, action) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> abort("Failed to #{action}; git exited with #{status}:\n#{output}")
    end
  end

  defp run_git!(root, args, action) do
    case git_output!(root, args, action) do
      "" -> :ok
      output -> IO.puts(output)
    end
  end

  def apply_prompt(relative_review, source_file, nil) do
    case Path.extname(source_file) do
      ".py" ->
        python_apply_prompt(relative_review, source_file)

      ext when ext in [".ex", ".exs", ".heex"] ->
        elixir_apply_prompt(relative_review, source_file)

      _ ->
        generic_apply_prompt(relative_review, source_file)
    end
  end

  def apply_prompt(relative_review, source_file, previous_rejection) do
    """
    A read-only review of the previous fix rejected it. Continue from the current working tree and implement the blocking issues below.

    Previous fix review output:
    #{String.trim(previous_rejection)}

    #{apply_prompt(relative_review, source_file, nil)}
    """
  end

  defp elixir_apply_prompt(relative_review, source_file) do
    apply_prompt_template(
      relative_review,
      source_file,
      """
      - Respect AGENTS.md and dependency usage rules; use `mix usage_rules.docs` or `mix usage_rules.search_docs` when changing framework or dependency APIs.
      - If a mechanical Elixir rename, move, create, or delete is the safest cleanup path, use `use-igniter` instead of hand edits.
      """
    )
  end

  defp python_apply_prompt(relative_review, source_file) do
    apply_prompt_template(
      relative_review,
      source_file,
      """
      - Respect AGENTS.md, README.md, pyproject.toml, and the existing Python/Airflow patterns.
      - Run the narrow relevant checks you can, such as `uv run ruff check airflow/dags airflow/tests`, `uv run ty check airflow/dags`, or focused `uv run python -m unittest ...` commands.
      """
    )
  end

  defp generic_apply_prompt(relative_review, source_file) do
    apply_prompt_template(
      relative_review,
      source_file,
      """
      - Respect AGENTS.md, README.md, package manifests, and the existing language/framework patterns.
      """
    )
  end

  defp apply_prompt_template(relative_review, source_file, language_guidance) do
    """
    Use the improve-codebase-architecture skill.
    Use design-an-interface if the review depends on choosing a better API, module, or file boundary.

    Apply the concrete refactoring and cleanup recommendations from `#{relative_review}`.
    The primary source file is `#{source_file}`.

    Instructions:
    - Read the review markdown and the relevant code before editing.
    - Keep changes focused on recommendations from the review.
    - You may move, rename, create, or delete files when the review calls for a clearer module or directory structure.
    #{language_guidance}
    - Run the narrow relevant tests or checks you can.
    - Add or update focused tests when behavior changes.
    - If a recommendation no longer applies, leave it unchanged and explain why in the final response.
    - Do not run git add, git commit, or delete the review markdown. The script will review, delete, stage, and commit after you finish.
    """
    |> String.replace("    #{language_guidance}", String.trim_trailing(language_guidance))
  end

  defp review_fix_prompt(relative_review, source_file) do
    """
    Review the working tree changes against `#{relative_review}`.
    The primary source file is `#{source_file}`.

    Instructions:
    - Do not edit files.
    - Read the review markdown and inspect the working tree diff.
    - Confirm the fix implements the concrete recommendations from the review.
    - Confirm any changed behavior has focused tests or a clear verification path.
    - Ignore unrelated pre-existing dirty files that are not part of this review.

    Output rules:
    - If the fix satisfies the review, output exactly:
    #{@fix_approved}
    - If the fix is incomplete or unsafe, output markdown starting with:
    FIX_REJECTED
    - After FIX_REJECTED, list the blocking issues the fixing agent must address.
    """
  end

  defp commit_message_prompt(relative_review, source_file) do
    """
    Generate a git commit subject for the working tree changes that apply `#{relative_review}`.
    The primary source file is `#{source_file}`.

    Instructions:
    - Read the review markdown and inspect the working tree diff.
    - Output only one concise commit subject line.
    - Do not use markdown, code fences, bullet points, quotes, or a trailing period.
    - Do not run git commands that modify the index or create commits.
    """
  end

  defp abort(message) do
    raise Review.Error, message
  end
end
