defmodule Review.Apply.Worktree do
  @moduledoc false

  alias Review.Apply.Git

  def apply!(root, target, job, base_head, apply_review) do
    repo_root = Git.repo_root!(root)
    branch = branch_name(job.relative_review)
    worktree = path(root, job.relative_review)
    worktree_root = profile_root_in_worktree(repo_root, root, worktree)

    try do
      IO.puts("Starting #{job.relative_review} in #{worktree}")
      Git.run!(root, ["worktree", "add", "-b", branch, worktree, base_head], "create worktree")
      sync_current_checkout_to_worktree!(root, worktree_root)
      copy_review_to_worktree!(root, worktree_root, job.relative_review)

      worktree_target =
        target
        |> Path.relative_to(root)
        |> then(&Path.join(worktree_root, &1))

      worktree_review = Path.join(worktree_root, job.relative_review)
      status = apply_review.(worktree_root, worktree_target, worktree_review)

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

  def cleanup!(root, %{worktree: worktree, branch: branch}) do
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

  defp branch_name(relative_review) do
    suffix = unique_suffix()

    review_slug =
      relative_review
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    "apply-review/#{review_slug}-#{suffix}"
  end

  defp path(root, relative_review) do
    review_slug =
      relative_review
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    Path.join(
      Git.common_dir!(root),
      "apply-review-worktrees/#{review_slug}-#{unique_suffix()}"
    )
  end

  defp unique_suffix do
    "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp profile_root_in_worktree(repo_root, root, worktree) do
    root
    |> Path.relative_to(repo_root)
    |> case do
      "." -> worktree
      relative_root -> Path.join(worktree, relative_root)
    end
  end

  defp sync_current_checkout_to_worktree!(root, worktree) do
    root_entries = checkout_entries!(root)
    worktree_entries = checkout_entries!(worktree)

    worktree_entries
    |> MapSet.difference(root_entries)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.each(fn entry ->
      remove_checkout_path!(Path.join(worktree, entry))
    end)

    root_entries
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.each(fn entry ->
      source = Path.join(root, entry)
      destination = Path.join(worktree, entry)

      remove_checkout_path!(destination)
      copy_checkout_path!(source, destination)
    end)
  end

  defp checkout_entries!(path) do
    path
    |> File.ls!()
    |> Enum.reject(&(&1 == ".git"))
    |> MapSet.new()
  end

  defp remove_checkout_path!(path) do
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

  defp abort(message) do
    raise Review.Error, message
  end
end
