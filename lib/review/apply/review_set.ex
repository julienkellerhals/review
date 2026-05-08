defmodule Review.Apply.ReviewSet do
  @moduledoc false

  alias Review.Common.SourcePolicy

  @source_file_pattern ~r/^Source file:\s+(.+?)$/

  def target(root, []) do
    Review.Common.Config.review_dir(root)
  end

  def target(root, [target | _rest]), do: Path.expand(target, root)

  def files(target) do
    cond do
      File.regular?(target) ->
        [target]

      File.dir?(target) ->
        reviews =
          target
          |> collect_review_files()
          |> Enum.sort()

        if reviews == [] do
          IO.puts("No review.md files found under #{target}")
          []
        else
          reviews
        end

      true ->
        abort("Expected a review directory or review.md file, got: #{target}")
    end
  end

  def build_job(root, target, source_policy, review_path) do
    relative_review = Path.relative_to(review_path, root)
    source_file = source_from_review(root, review_path, target)

    case validate_source_file(root, source_policy, relative_review, source_file) do
      :ok ->
        case affected_files_for_review(root, relative_review, review_path, source_file) do
          {:ok, affected_files} ->
            {:ok,
             %{
               review_path: review_path,
               relative_review: relative_review,
               source_file: source_file,
               affected_files: affected_files
             }}

          {:skip, message} ->
            {:skip_invalid_affected_file, message}
        end

      {:stale, message} ->
        {:stale, source_file, message}
    end
  end

  def source_from_review(root, review_path, target) do
    review_path
    |> File.stream!()
    |> Enum.find_value("", fn line ->
      case Regex.run(@source_file_pattern, String.trim(line)) do
        [_line, source_file] -> clean_metadata_path(source_file)
        _ -> nil
      end
    end)
    |> fallback_source_from_path(root, review_path, target)
  end

  def stale_source_message(relative_review, source_file) do
    "Source file no longer exists or has an unsupported extension for #{relative_review}: #{source_file}"
  end

  def clean_metadata_path(path) do
    path
    |> String.trim()
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
    |> String.trim()
  end

  defp collect_review_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) -> collect_review_files(path)
        File.regular?(path) and Path.basename(path) == "review.md" -> [Path.expand(path)]
        true -> []
      end
    end)
  end

  defp affected_files_for_review(root, relative_review, review_path, source_file) do
    review_path
    |> affected_files_from_review()
    |> then(&[source_file | &1])
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, files} ->
      case normalize_affected_path(root, relative_review, path) do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        {:skip, message} -> {:halt, {:skip, message}}
      end
    end)
    |> case do
      {:ok, files} ->
        affected_files =
          files
          |> Enum.reverse()
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, affected_files}

      {:skip, message} ->
        {:skip, message}
    end
  end

  defp affected_files_from_review(review_path) do
    review_path
    |> File.stream!()
    |> Enum.reduce_while({:searching, []}, fn line, {mode, files} ->
      trimmed = String.trim(line)

      cond do
        mode == :searching and trimmed == "Affected files:" ->
          {:cont, {:collecting, files}}

        mode == :searching and String.starts_with?(trimmed, "Affected files:") ->
          {:halt,
           {:error,
            "Malformed affected files metadata in #{review_path}: expected `Affected files:` on its own line followed by repo-relative bullet items"}}

        mode == :searching ->
          {:cont, {mode, files}}

        mode == :collecting and trimmed == "" and files != [] ->
          {:halt, {:done, files}}

        mode == :collecting and trimmed == "" ->
          {:halt,
           {:error,
            "Malformed affected files metadata in #{review_path}: expected repo-relative bullet items after `Affected files:`"}}

        mode == :collecting and String.starts_with?(trimmed, "- ") ->
          path = trimmed |> String.trim_leading("- ") |> clean_metadata_path()

          cond do
            path == "" ->
              {:halt,
               {:error,
                "Malformed affected files metadata in #{review_path}: empty bullet item under `Affected files:`"}}

            true ->
              {:cont, {:collecting, files ++ [path]}}
          end

        mode == :collecting and String.starts_with?(trimmed, "#") and files != [] ->
          {:halt, {:done, files}}

        mode == :collecting ->
          {:halt,
           {:error,
            "Malformed affected files metadata in #{review_path}: expected repo-relative bullet items after `Affected files:`"}}
      end
    end)
    |> case do
      {:done, files} ->
        files

      {:searching, files} ->
        files

      {:collecting, []} ->
        abort(
          "Malformed affected files metadata in #{review_path}: expected repo-relative bullet items after `Affected files:`"
        )

      {:collecting, files} ->
        files

      {:error, message} ->
        abort(message)
    end
  end

  defp normalize_affected_path(root, relative_review, path) do
    path =
      path
      |> String.trim()
      |> String.trim_leading("./")

    expanded = Path.expand(path, root)

    if Review.Common.Repo.under_root?(root, expanded) do
      {:ok, Path.relative_to(expanded, root)}
    else
      {:skip,
       """
       Affected file escapes the repository root for #{relative_review}: #{path}

       `mix review.apply` can only apply and commit changes inside #{root}.
       Run it from the repository that owns this path, or split this review so every affected file is inside the current checkout.
       """}
    end
  end

  defp fallback_source_from_path("", root, review_path, target) do
    target_dir =
      if File.dir?(target) do
        target
      else
        Review.Common.Config.review_dir(root)
      end

    relative_review = Path.relative_to(review_path, target_dir)

    if String.ends_with?(relative_review, "/review.md") do
      String.replace_suffix(relative_review, "/review.md", "")
    else
      ""
    end
  end

  defp fallback_source_from_path(source_file, _root, _review_path, _target), do: source_file

  def validate_source_file(root, source_policy, relative_review, source_file) do
    absolute_source = Path.expand(source_file, root)

    if source_file == "" do
      abort("Could not infer source file for #{relative_review}")
    end

    unless Review.Common.Repo.under_root?(root, absolute_source) do
      abort("Expected source file under #{root} for #{relative_review}: #{source_file}")
    end

    unless SourcePolicy.allowed_path?(root, absolute_source, source_policy) do
      abort(disallowed_source_message(root, absolute_source, source_policy, relative_review))
    end

    if File.regular?(absolute_source) and
         SourcePolicy.source_file_extension?(absolute_source, source_policy) do
      :ok
    else
      {:stale, stale_source_message(relative_review, source_file)}
    end
  end

  defp abort(message) do
    raise Review.Error, message
  end

  defp disallowed_source_message(root, absolute_source, source_policy, relative_review) do
    source_file = Path.relative_to(absolute_source, root)

    case SourcePolicy.exclusion_reason(root, absolute_source, source_policy) do
      {:blacklisted, blacklist} ->
        "Source file is under a blacklisted folder (#{SourcePolicy.format_source_blacklist(blacklist)}) for #{relative_review}: #{source_file}"

      {:outside_source_dirs, source_dirs} ->
        "Source file is outside configured source_dirs (#{SourcePolicy.format_source_dirs(source_dirs)}) for #{relative_review}: #{source_file}"
    end
  end
end
