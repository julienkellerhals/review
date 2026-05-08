defmodule Review.Generate.ReviewDocument do
  @moduledoc false

  def write_actionable_review(tmp_path, review_path, relative_source) do
    content =
      case File.read(tmp_path) do
        {:ok, content} -> IO.iodata_to_binary(content)
        {:error, _reason} -> ""
      end

    if actionable_review?(content, relative_source) do
      File.mkdir_p!(Path.dirname(review_path))
      File.write!(review_path, content)
      IO.puts("Wrote #{review_path}")
    else
      File.rm(review_path)
      IO.puts("Skipped #{relative_source}: no actionable review")
    end

    File.rm(tmp_path)
    :ok
  end

  defp actionable_review?(content, relative_source) do
    trimmed = String.trim(content)

    trimmed != "" and
      trimmed != "NO_ACTIONABLE_REVIEW" and
      valid_actionable_review?(trimmed, relative_source)
  end

  defp valid_actionable_review?(content, relative_source) do
    expected_title = "# Review: #{relative_source}"
    expected_source_line = "Source file: `#{relative_source}`"

    case :binary.split(content, "\n", [:global]) do
      [title, source_line, affected_line | rest]
      when title == expected_title and
             source_line == expected_source_line and
             affected_line == "Affected files:" ->
        with {:ok, paths, body} <- collect_metadata_paths(rest, []),
             true <- relative_source in paths,
             true <- valid_section_headings?(body) do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp collect_metadata_paths([], paths) when paths != [] do
    {:ok, Enum.reverse(paths), []}
  end

  defp collect_metadata_paths(["" | rest], paths) when paths != [] do
    {:ok, Enum.reverse(paths), rest}
  end

  defp collect_metadata_paths(["- `" <> rest | more], paths) do
    path = String.trim_trailing(rest, "`")

    if path != "" and String.ends_with?(rest, "`") do
      collect_metadata_paths(more, [path | paths])
    else
      :error
    end
  end

  defp collect_metadata_paths(["## " <> _ = heading | rest], paths) when paths != [] do
    {:ok, Enum.reverse(paths), [heading | rest]}
  end

  defp collect_metadata_paths([_line | _rest], _paths), do: :error
  defp collect_metadata_paths([], _paths), do: :error

  defp valid_section_headings?(content) do
    required = MapSet.new(["Overview", "Findings", "Recommendations", "Verification"])

    headings =
      content
      |> Enum.flat_map(fn line ->
        if String.starts_with?(line, "## ") do
          [line |> String.trim_leading("## ") |> String.trim()]
        else
          []
        end
      end)

    headings_set = MapSet.new(headings)
    MapSet.subset?(required, headings_set) and MapSet.subset?(headings_set, required)
  end
end
