defmodule Review.Apply.Transaction do
  @moduledoc false

  alias Review.Apply.Codex
  alias Review.Apply.Lifecycle
  alias Review.Apply.ReviewSet

  @deferred_review_start "<!-- apply-review-deferred-start -->"
  @deferred_review_end "<!-- apply-review-deferred-end -->"

  def apply(root, target, source_blacklist, review_path, opts) do
    max_attempts = Keyword.fetch!(opts, :max_attempts)
    relative_review = Path.relative_to(review_path, root)
    source_file = ReviewSet.source_from_review(root, review_path, target)
    baseline_head = Lifecycle.git_head(root)
    baseline_paths = Lifecycle.changed_path_set(root)

    case ReviewSet.validate_source_file(root, source_blacklist, relative_review, source_file) do
      :ok ->
        case apply_until_review_approved!(
               root,
               relative_review,
               source_file,
               baseline_head,
               baseline_paths,
               max_attempts
             ) do
          :approved ->
            delete_review!(review_path, relative_review)

            paths = Lifecycle.commit_paths(root, baseline_paths, [relative_review])

            Lifecycle.commit_review_changes!(
              paths,
              root,
              relative_review,
              fn -> Codex.commit_message(root, relative_review, source_file) end
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
        skip_stale(root, review_path, relative_review, source_file, message)
        :skipped_stale
    end
  end

  def skip_stale(root, review_path, relative_review, source_file, message) do
    baseline_paths = Lifecycle.changed_path_set(root)
    IO.puts("Skipping stale review #{relative_review}: #{source_file}")
    IO.puts(message)
    delete_review!(review_path, relative_review)

    paths = Lifecycle.commit_paths(root, baseline_paths, [relative_review])

    Lifecycle.commit_review_changes!(paths, root, relative_review, fn ->
      "Remove stale review"
    end)
  end

  defp apply_until_review_approved!(
         root,
         relative_review,
         source_file,
         baseline_head,
         baseline_paths,
         max_attempts
       ) do
    1..max_attempts
    |> Enum.reduce_while(nil, fn attempt, previous_rejection ->
      if attempt == 1 do
        IO.puts("Applying #{relative_review}")
      else
        IO.puts("Re-applying #{relative_review} after fix review rejection")
      end

      Codex.apply_review(root, relative_review, source_file, previous_rejection)

      Lifecycle.ensure_head_unchanged!(root, baseline_head, relative_review)

      case review_fix_result!(root, relative_review, source_file, baseline_paths) do
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

  defp review_fix_result!(root, relative_review, source_file, baseline_paths) do
    IO.puts("Reviewing fix against #{relative_review}")
    Lifecycle.expose_new_untracked_files_to_diff!(root, baseline_paths, relative_review)
    Codex.review_fix(root, relative_review, source_file)
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

    Lifecycle.discard_new_changes!(root, baseline_paths, relative_review)
    write_deferred_review!(review_path, relative_review, rejection, max_attempts)
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

  defp abort(message) do
    raise Review.Error, message
  end
end
