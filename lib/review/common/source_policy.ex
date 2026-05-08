defmodule Review.Common.SourcePolicy do
  @moduledoc false

  @source_file_extensions [
    ".css",
    ".ex",
    ".exs",
    ".heex",
    ".js",
    ".jsx",
    ".py",
    ".ts",
    ".tsx"
  ]

  @default_source_blacklist [
    ".codex",
    ".elixir_ls",
    ".git",
    ".kanban_ai",
    ".next",
    "_build",
    "build",
    "cover",
    "deps",
    "dist",
    "node_modules",
    "vendor"
  ]

  def source_file_extension?(path) do
    Path.extname(path) in @source_file_extensions
  end

  def source_blacklist do
    "REVIEW_SOURCE_BLACKLIST"
    |> System.get_env(Enum.join(@default_source_blacklist, ","))
    |> parse_source_blacklist()
  end

  def blacklisted_path?(root, path, blacklist) when is_list(blacklist) do
    relative_path = Path.relative_to(path, root)
    path_parts = Path.split(relative_path)

    Enum.any?(blacklist, &(&1 in path_parts))
  end

  def format_source_blacklist([]), do: "(none)"

  def format_source_blacklist(blacklist) do
    Enum.join(blacklist, ", ")
  end

  defp parse_source_blacklist(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_source_blacklist_entry/1)
    |> Enum.uniq()
  end

  defp parse_source_blacklist_entry(entry) do
    case Regex.run(~r/^\*\*\/([^\/]+)\/?$/, entry) do
      [_entry, folder] ->
        folder

      _ ->
        if String.contains?(entry, "/") do
          raise Review.Error,
                "Expected blacklist entry to be `name` or `**/name/`, got: #{inspect(entry)}"
        end

        entry
    end
  end
end
