defmodule Review.Common.Config do
  @moduledoc false

  @default_review_dir "review"
  @default_source_dirs ["."]
  @default_source_dirs_mode :discover
  @default_source_file_extensions [
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

  def review_dir(root, profile \\ nil) do
    dir =
      case System.get_env("REVIEW_DIR") do
        nil -> Review.Common.Profile.value(profile, :review_dir, @default_review_dir)
        "" -> Review.Common.Profile.value(profile, :review_dir, @default_review_dir)
        value -> value
      end

    dir
    |> normalize_review_dir!()
    |> Path.expand(root)
  end

  def source_dirs(profile \\ nil) do
    profile
    |> Review.Common.Profile.value(:source_dirs, @default_source_dirs)
    |> normalize_source_dirs!()
  end

  def source_dirs_mode(profile \\ nil) do
    profile
    |> Review.Common.Profile.value(:source_dirs_mode, @default_source_dirs_mode)
    |> normalize_source_dirs_mode!()
  end

  def source_file_extensions(profile \\ nil) do
    profile
    |> Review.Common.Profile.value(:source_file_extensions, @default_source_file_extensions)
    |> normalize_source_file_extensions!()
  end

  def source_blacklist(profile \\ nil) do
    profile
    |> Review.Common.Profile.value(:source_blacklist, @default_source_blacklist)
    |> normalize_source_path_filter!(:source_blacklist)
  end

  defp normalize_review_dir!(dir) when is_binary(dir) do
    dir = String.trim(dir)

    if dir == "" do
      raise Review.Error, "Expected :review, :review_dir to be a non-empty path"
    end

    dir
  end

  defp normalize_review_dir!(value) do
    raise Review.Error, "Expected :review, :review_dir to be a path, got: #{inspect(value)}"
  end

  defp normalize_source_dirs!(dirs) when is_list(dirs) do
    dirs
    |> Enum.map(&normalize_source_dir!/1)
    |> Enum.uniq()
  end

  defp normalize_source_dirs!(value) do
    raise Review.Error,
          "Expected :review, :source_dirs to be a list of repo-relative paths, got: #{inspect(value)}"
  end

  defp normalize_source_dir!(dir) when is_binary(dir) do
    dir = String.trim(dir)

    cond do
      dir == "" ->
        raise Review.Error, "Expected :review, :source_dirs entries to be non-empty paths"

      Path.type(dir) == :absolute ->
        raise Review.Error,
              "Expected :review, :source_dirs entries to be repo-relative paths, got: #{inspect(dir)}"

      true ->
        dir
    end
  end

  defp normalize_source_dir!(value) do
    raise Review.Error,
          "Expected :review, :source_dirs entries to be repo-relative paths, got: #{inspect(value)}"
  end

  defp normalize_source_dirs_mode!(mode) when mode in [:discover, :whitelist], do: mode

  defp normalize_source_dirs_mode!(mode) when mode in ["discover", "whitelist"] do
    String.to_existing_atom(mode)
  end

  defp normalize_source_dirs_mode!(value) do
    raise Review.Error,
          "Expected :review, :source_dirs_mode to be :discover or :whitelist, got: #{inspect(value)}"
  end

  defp normalize_source_file_extensions!(extensions) when is_list(extensions) do
    extensions
    |> Enum.map(&normalize_source_file_extension!/1)
    |> Enum.uniq()
  end

  defp normalize_source_file_extensions!(value) do
    raise Review.Error,
          "Expected :review, :source_file_extensions to be a list of extensions, got: #{inspect(value)}"
  end

  defp normalize_source_file_extension!(extension) when is_binary(extension) do
    extension = String.trim(extension)

    cond do
      extension == "" ->
        raise Review.Error,
              "Expected :review, :source_file_extensions entries to be non-empty extensions"

      not String.starts_with?(extension, ".") ->
        raise Review.Error,
              "Expected :review, :source_file_extensions entries to start with `.`, got: #{inspect(extension)}"

      String.contains?(extension, "/") ->
        raise Review.Error,
              "Expected :review, :source_file_extensions entries to be extensions, got: #{inspect(extension)}"

      true ->
        extension
    end
  end

  defp normalize_source_file_extension!(value) do
    raise Review.Error,
          "Expected :review, :source_file_extensions entries to be extensions, got: #{inspect(value)}"
  end

  defp normalize_source_path_filter!(filter, name) when is_list(filter) do
    filter
    |> Enum.map(&normalize_source_path_filter_entry!(&1, name))
    |> Enum.uniq()
  end

  defp normalize_source_path_filter!(value, name) do
    raise Review.Error,
          "Expected :review, :#{name} to be a list of folder names, got: #{inspect(value)}"
  end

  defp normalize_source_path_filter_entry!(entry, name) when is_binary(entry) do
    entry = String.trim(entry)

    cond do
      entry == "" ->
        raise Review.Error, "Expected :review, :#{name} entries to be non-empty names"

      String.contains?(entry, "/") ->
        raise Review.Error,
              "Expected :review, :#{name} entries to be folder names, got: #{inspect(entry)}"

      true ->
        entry
    end
  end

  defp normalize_source_path_filter_entry!(value, name) do
    raise Review.Error,
          "Expected :review, :#{name} entries to be folder names, got: #{inspect(value)}"
  end
end
