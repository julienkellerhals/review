defmodule Review.Apply.Terminal do
  @moduledoc false

  @line_width 78

  def plan(review_count, batch_count, concurrency) do
    section("Review apply", [
      row("reviews", review_count),
      row("batches", batch_count),
      row("parallel agents", "up to #{concurrency}")
    ])
  end

  def batch_start(index, total, batch, concurrency) do
    heading("batch #{index}/#{total}", [
      "#{length(batch)} review(s)",
      "#{min(length(batch), concurrency)} agent(s)"
    ])

    Enum.each(batch, fn job ->
      item(job.relative_review, "affects #{Enum.join(job.affected_files, ", ")}")
    end)
  end

  def batch_done(remaining) do
    status(:ok, "batch complete", "#{remaining} implementation step(s) remaining")
  end

  def review_start(relative_review) do
    status(:work, "apply", relative_review)
  end

  def review_retry(relative_review) do
    status(:work, "re-apply", "#{relative_review} after fix review rejection")
  end

  def fix_review(relative_review) do
    status(:check, "fix review", relative_review)
  end

  def fix_rejected(relative_review, rejection) do
    status(:warn, "fix rejected", relative_review, :stderr)
    block(String.trim_trailing(rejection), :stderr)
  end

  def fix_rejected_final(relative_review, max_attempts, rejection) do
    status(:warn, "fix rejected", "#{relative_review} after #{max_attempts} attempt(s)", :stderr)
    block(String.trim_trailing(rejection), :stderr)
  end

  def deferred(relative_review, max_attempts) do
    status(
      :warn,
      "deferred",
      "#{relative_review} after #{max_attempts} rejected attempt(s); recorded feedback and continuing"
    )
  end

  def stale(relative_review, source_file, message) do
    status(:skip, "stale", "#{relative_review}: #{source_file}")
    block(String.trim_trailing(message))
  end

  def deleted(relative_review) do
    status(:ok, "deleted", relative_review)
  end

  def deferred_updated(relative_review) do
    status(:ok, "updated", "#{relative_review} with latest failed fix review output")
  end

  def no_changes(relative_review) do
    status(:skip, "already applied", "#{relative_review}; no new committable changes")
  end

  def committed(relative_review, commit_message) do
    status(:ok, "committed", "#{relative_review}: #{commit_message}")
  end

  def left_uncommitted(relative_review) do
    status(:ok, "uncommitted", "#{relative_review}; changes left in working tree")
  end

  def worktree_start(relative_review, worktree) do
    status(:work, "worktree", "#{relative_review} in #{worktree}")
  end

  def merge_start(relative_review, branch) do
    status(:work, "merge", "#{relative_review} from #{branch}")
  end

  def retry_after_merge_conflict(relative_review) do
    status(:warn, "merge retry", "#{relative_review} sequentially from current branch head")
    info("The failed parallel merge was aborted before retrying.")
  end

  def command_output(""), do: :ok

  def command_output(output) do
    block(String.trim_trailing(output))
  end

  def info(message), do: status(:info, "info", message)
  def warning(message), do: status(:warn, "warning", message)

  defp section(title, rows) do
    border = "+" <> String.duplicate("-", @line_width - 2) <> "+"
    IO.puts(border)
    IO.puts("| " <> pad(title, @line_width - 4) <> " |")
    IO.puts("|" <> String.duplicate("-", @line_width - 2) <> "|")

    Enum.each(rows, fn {label, value} ->
      content = "  " <> label <> String.duplicate(" ", max(1, 18 - String.length(label))) <> value
      IO.puts("| " <> pad(content, @line_width - 4) <> " |")
    end)

    IO.puts(border)
  end

  defp heading(label, details) do
    IO.puts("")
    IO.puts("[#{label}] " <> Enum.join(details, " | "))
  end

  defp item(label, detail) do
    IO.puts("  - " <> label)
    IO.puts("    " <> detail)
  end

  defp status(kind, label, message, device \\ :stdio) do
    IO.puts(device, "#{marker(kind)} #{String.pad_trailing(label, 15)} #{message}")
  end

  defp block(content, device \\ :stdio)

  defp block("", _device), do: :ok

  defp block(content, device) do
    content
    |> String.split("\n")
    |> Enum.each(&IO.puts(device, "    " <> &1))
  end

  defp row(label, value), do: {label, to_string(value)}

  defp marker(:ok), do: "[ok]"
  defp marker(:work), do: "[run]"
  defp marker(:check), do: "[chk]"
  defp marker(:warn), do: "[warn]"
  defp marker(:skip), do: "[skip]"
  defp marker(:info), do: "[info]"

  defp pad(content, width) do
    String.slice(content <> String.duplicate(" ", width), 0, width)
  end
end
