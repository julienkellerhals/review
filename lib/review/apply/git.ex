defmodule Review.Apply.Git do
  @moduledoc false

  alias Review.Apply.Terminal

  def current_branch!(root) do
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

  def head(root) do
    root
    |> output!(["rev-parse", "HEAD"], "read HEAD")
    |> String.trim()
  end

  def common_dir!(root) do
    root
    |> output!(["rev-parse", "--git-common-dir"], "read git common directory")
    |> String.trim()
    |> Path.expand(root)
  end

  def repo_root!(root) do
    root
    |> output!(["rev-parse", "--show-toplevel"], "read repository root")
    |> String.trim()
    |> Path.expand()
  end

  def changed_path_set(root) do
    root
    |> output!(["status", "--porcelain=v1", "-z", "--untracked-files=all"], "read git status")
    |> parse_status_entries()
    |> Enum.map(&path_relative_to_checkout_root(root, &1))
    |> MapSet.new()
  end

  def staged_path_set(root) do
    root
    |> output!(["diff", "--cached", "--name-only", "-z"], "read staged paths")
    |> String.split(<<0>>, trim: true)
    |> Enum.map(&path_relative_to_checkout_root(root, &1))
    |> MapSet.new()
  end

  def untracked_path_set(root) do
    root
    |> output!(["ls-files", "--others", "--exclude-standard", "-z"], "read untracked paths")
    |> String.split(<<0>>, trim: true)
    |> Enum.map(&path_relative_to_checkout_root(root, &1))
    |> MapSet.new()
  end

  def tracked_in_head?(root, path) do
    root
    |> output!(["ls-tree", "-r", "--name-only", "HEAD", "--", path], "inspect HEAD")
    |> String.split("\n", trim: true)
    |> Enum.member?(path)
  end

  def merge_in_progress?(root) do
    case System.cmd("git", ["rev-parse", "-q", "--verify", "MERGE_HEAD"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

  def staged_changes?(root) do
    case System.cmd("git", ["diff", "--cached", "--quiet", "--exit-code"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        false

      {_, 1} ->
        true

      {output, status} ->
        abort("Failed checking staged changes; git exited with #{status}:\n#{output}")
    end
  end

  def output!(root, args, action) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> abort("Failed to #{action}; git exited with #{status}:\n#{output}")
    end
  end

  def run!(root, args, action) do
    case output!(root, args, action) do
      "" -> :ok
      output -> Terminal.command_output(output)
    end
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

  defp path_relative_to_checkout_root(root, path) do
    root
    |> repo_root!()
    |> Path.join(path)
    |> Path.expand()
    |> Path.relative_to(root)
  end

  defp abort(message) do
    raise Review.Error, message
  end
end
