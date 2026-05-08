defmodule Review.Generate.SourceSet do
  @moduledoc false

  alias Review.Common.SourcePolicy

  def files(root, [], review_dir, source_policy, source_dirs) do
    root
    |> discover_source_files(review_dir, source_policy, source_dirs)
    |> Enum.sort()
  end

  def files(root, args, _review_dir, source_policy, _source_dirs) do
    Enum.map(args, &validate_source_file!(root, &1, source_policy))
  end

  def discover_source_files(
        root,
        review_dir,
        source_policy,
        source_dirs \\ Review.Common.Config.source_dirs()
      ) do
    root = Path.expand(root)
    review_dir = Path.expand(review_dir, root)

    source_dirs
    |> Enum.flat_map(&discover_source_path(root, &1, review_dir, source_policy))
    |> Enum.uniq()
  end

  defp validate_source_file!(root, path, source_policy) do
    source = Path.expand(path, root)

    cond do
      not Review.Common.Repo.under_root?(root, source) ->
        abort("Expected a file under #{root}, got: #{source}")

      not SourcePolicy.allowed_path?(root, source, source_policy) ->
        abort(disallowed_source_message(root, source, source_policy))

      not File.regular?(source) or not SourcePolicy.source_file_extension?(source, source_policy) ->
        abort("Expected an existing supported source file, got: #{source}")

      true ->
        source
    end
  end

  defp discover_source_path(root, source_dir, review_dir, source_policy) do
    source_path = Path.expand(source_dir, root)

    cond do
      not Review.Common.Repo.under_root?(root, source_path) ->
        abort("Configured source dir must be under #{root}, got: #{source_path}")

      not File.exists?(source_path) ->
        abort("Configured source dir does not exist: #{source_dir}")

      not SourcePolicy.allowed_path?(root, source_path, source_policy) ->
        []

      File.dir?(source_path) ->
        walk(root, source_path, review_dir, source_policy)

      File.regular?(source_path) and
          SourcePolicy.source_file_extension?(source_path, source_policy) ->
        [Path.expand(source_path)]

      true ->
        []
    end
  end

  defp walk(root, dir, review_dir, source_policy) do
    if Path.expand(dir) == review_dir do
      []
    else
      dir
      |> File.ls!()
      |> Enum.flat_map(fn entry ->
        path = Path.join(dir, entry)

        cond do
          not SourcePolicy.allowed_path?(root, path, source_policy) ->
            []

          File.dir?(path) ->
            walk(root, path, review_dir, source_policy)

          File.regular?(path) and SourcePolicy.source_file_extension?(path, source_policy) ->
            [Path.expand(path)]

          true ->
            []
        end
      end)
    end
  end

  defp abort(message) do
    raise Review.Error, message
  end

  defp disallowed_source_message(root, source, source_policy) do
    case SourcePolicy.exclusion_reason(root, source, source_policy) do
      {:blacklisted, blacklist} ->
        "Source file is under a blacklisted folder (#{SourcePolicy.format_source_blacklist(blacklist)}): #{Path.relative_to(source, root)}"

      {:outside_source_dirs, source_dirs} ->
        "Source file is outside configured source_dirs (#{SourcePolicy.format_source_dirs(source_dirs)}): #{Path.relative_to(source, root)}"
    end
  end
end
