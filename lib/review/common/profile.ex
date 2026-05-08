defmodule Review.Common.Profile do
  @moduledoc false

  @default_root "."

  def split_arg(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [profile: :string],
        aliases: [p: :profile]
      )

    if invalid != [] do
      invalid_args =
        invalid
        |> Enum.map_join(" ", fn
          {key, nil} -> key
          {key, value} -> "#{key} #{value}"
        end)

      raise Review.Error, "Unknown review arguments: #{invalid_args}"
    end

    {options[:profile], rest}
  end

  def root(repo_root, profile \\ nil) do
    root =
      profile
      |> value(:root, @default_root)
      |> normalize_root!()
      |> Path.expand(repo_root)

    unless Review.Common.Repo.under_root?(repo_root, root) do
      raise Review.Error, "Expected :review profile root to be under #{repo_root}, got: #{root}"
    end

    root
  end

  def value(profile, key, default) do
    profile
    |> config()
    |> Keyword.get(key, Application.get_env(:review, key, default))
  end

  defp config(nil) do
    profiles = profiles()

    if Keyword.has_key?(profiles, :default) do
      Keyword.fetch!(profiles, :default)
    else
      []
    end
  end

  defp config(profile) when is_binary(profile) do
    Enum.find_value(profiles(), fn {name, config} ->
      if to_string(name) == profile do
        config
      end
    end) ||
      raise Review.Error, "Unknown review profile: #{profile}"
  end

  defp config(profile) when is_atom(profile) do
    profile
    |> to_string()
    |> config()
  end

  defp profiles do
    :review
    |> Application.get_env(:profiles, [])
    |> normalize_profiles!()
  end

  defp normalize_profiles!(profiles) when is_list(profiles) do
    Enum.map(profiles, fn
      {name, config} when (is_atom(name) or is_binary(name)) and is_list(config) ->
        {name, config}

      value ->
        raise Review.Error,
              "Expected :review, :profiles to be a keyword list of profile configs, got: #{inspect(value)}"
    end)
  end

  defp normalize_profiles!(value) do
    raise Review.Error,
          "Expected :review, :profiles to be a keyword list, got: #{inspect(value)}"
  end

  defp normalize_root!(root) when is_binary(root) do
    root = String.trim(root)

    cond do
      root == "" ->
        raise Review.Error, "Expected :review profile root to be a non-empty path"

      Path.type(root) == :absolute ->
        raise Review.Error, "Expected :review profile root to be repo-relative, got: #{root}"

      true ->
        root
    end
  end

  defp normalize_root!(value) do
    raise Review.Error, "Expected :review profile root to be a path, got: #{inspect(value)}"
  end
end
