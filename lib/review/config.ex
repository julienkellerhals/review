defmodule Review.Config do
  @moduledoc false

  @default_source_dirs ["."]

  def source_dirs do
    :review
    |> Application.get_env(:source_dirs, @default_source_dirs)
    |> normalize_source_dirs!()
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
end
