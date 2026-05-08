defmodule Review.Common.SourcePolicy do
  @moduledoc false

  defstruct blacklist: [], extensions: [], source_dirs: [], source_dirs_mode: :discover

  def source_file_extension?(path, source_policy \\ source_policy()) do
    Path.extname(path) in source_policy.extensions
  end

  def source_policy(profile \\ nil) do
    %__MODULE__{
      blacklist: source_blacklist(profile),
      extensions: Review.Common.Config.source_file_extensions(profile),
      source_dirs: Review.Common.Config.source_dirs(profile),
      source_dirs_mode: Review.Common.Config.source_dirs_mode(profile)
    }
  end

  def source_blacklist(profile \\ nil) do
    case System.get_env("REVIEW_SOURCE_BLACKLIST") do
      nil -> Review.Common.Config.source_blacklist(profile)
      "" -> Review.Common.Config.source_blacklist(profile)
      value -> parse_source_blacklist(value)
    end
  end

  def blacklisted_path?(root, path, blacklist) when is_list(blacklist) do
    relative_path = Path.relative_to(path, root)
    path_parts = Path.split(relative_path)

    Enum.any?(blacklist, &(&1 in path_parts))
  end

  def allowed_path?(root, path, %__MODULE__{blacklist: blacklist} = policy) do
    not blacklisted_path?(root, path, blacklist) and source_dir_allowed?(root, path, policy)
  end

  def exclusion_reason(root, path, %__MODULE__{blacklist: blacklist} = policy) do
    cond do
      blacklisted_path?(root, path, blacklist) ->
        {:blacklisted, blacklist}

      not source_dir_allowed?(root, path, policy) ->
        {:outside_source_dirs, policy.source_dirs}

      true ->
        nil
    end
  end

  def format_source_blacklist([]), do: "(none)"

  def format_source_blacklist(blacklist) do
    Enum.join(blacklist, ", ")
  end

  def format_source_dirs(source_dirs) do
    Enum.join(source_dirs, ", ")
  end

  defp source_dir_allowed?(_root, _path, %__MODULE__{source_dirs_mode: :discover}), do: true

  defp source_dir_allowed?(root, path, %__MODULE__{
         source_dirs_mode: :whitelist,
         source_dirs: source_dirs
       }) do
    path = Path.expand(path)

    Enum.any?(source_dirs, fn source_dir ->
      source_path = Path.expand(source_dir, root)

      source_path == root or path == source_path or String.starts_with?(path, source_path <> "/")
    end)
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
