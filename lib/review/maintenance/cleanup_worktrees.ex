defmodule Review.Maintenance.CleanupWorktrees do
  def main(["-h"]), do: usage()
  def main(["--help"]), do: usage()

  def main(_args) do
    root = Review.Common.Repo.root!()
    worktrees = linked_worktrees(root)

    case worktrees do
      [] ->
        IO.puts("No linked worktrees to remove for #{root}")

      _ ->
        IO.puts("Removing #{length(worktrees)} linked worktree(s) for #{root}")

        Enum.each(worktrees, fn worktree ->
          IO.puts("Removing #{worktree}")

          run_git!(
            root,
            ["worktree", "remove", "--force", worktree],
            "remove linked worktree #{worktree}"
          )
        end)
    end

    run_git!(root, ["worktree", "prune"], "prune stale worktree metadata")
  end

  defp usage do
    IO.puts("Usage: mix review.cleanup_worktrees")
    IO.puts("Removes every linked git worktree for this repository except the current checkout.")
    IO.puts("Also runs `git worktree prune` afterward.")
  end

  defp linked_worktrees(root) do
    root
    |> git_output!(["worktree", "list", "--porcelain"], "list worktrees")
    |> parse_worktree_paths()
    |> Enum.map(&Path.expand/1)
    |> Enum.reject(&(&1 == root))
  end

  defp parse_worktree_paths(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "worktree " <> path -> [path]
      _line -> []
    end)
  end

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

  defp abort(message) do
    raise Review.Error, message
  end
end
