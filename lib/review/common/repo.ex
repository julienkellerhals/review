defmodule Review.Common.Repo do
  @moduledoc false

  def root(fallback \\ File.cwd!()) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> root |> String.trim() |> Path.expand()
      _ -> fallback
    end
  end

  def root! do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} ->
        root
        |> String.trim()
        |> Path.expand()

      {output, status} ->
        raise Review.Error,
              "Failed to locate repository root; git exited with #{status}:\n#{output}"
    end
  end

  def under_root?(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)

    path == root or String.starts_with?(path, root <> "/")
  end
end
