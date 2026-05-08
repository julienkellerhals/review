defmodule Review.Generate.SourceSet do
  @moduledoc false

  alias Review.Common.SourcePolicy

  def files(root, [], review_dir, source_blacklist, source_dirs) do
    root
    |> discover_source_files(review_dir, source_blacklist, source_dirs)
    |> Enum.sort()
  end

  def files(root, args, _review_dir, source_blacklist, _source_dirs) do
    Enum.map(args, &validate_source_file!(root, &1, source_blacklist))
  end

  def discover_source_files(
        root,
        review_dir,
        source_blacklist,
        source_dirs \\ Review.Common.Config.source_dirs()
      ) do
    root = Path.expand(root)
    review_dir = Path.expand(review_dir, root)

    source_dirs
    |> Enum.flat_map(&discover_source_path(root, &1, review_dir, source_blacklist))
    |> Enum.uniq()
  end

  defp validate_source_file!(root, path, source_blacklist) do
    source = Path.expand(path, root)

    cond do
      not Review.Common.Repo.under_root?(root, source) ->
        abort("Expected a file under #{root}, got: #{source}")

      SourcePolicy.blacklisted_path?(root, source, source_blacklist) ->
        abort("Expected an existing supported source file, got: #{source}")

      not File.regular?(source) or not SourcePolicy.source_file_extension?(source) ->
        abort("Expected an existing supported source file, got: #{source}")

      true ->
        source
    end
  end

  defp discover_source_path(root, source_dir, review_dir, source_blacklist) do
    source_path = Path.expand(source_dir, root)

    cond do
      not Review.Common.Repo.under_root?(root, source_path) ->
        abort("Configured source dir must be under #{root}, got: #{source_path}")

      not File.exists?(source_path) ->
        abort("Configured source dir does not exist: #{source_dir}")

      SourcePolicy.blacklisted_path?(root, source_path, source_blacklist) ->
        []

      File.dir?(source_path) ->
        walk(root, source_path, review_dir, source_blacklist)

      File.regular?(source_path) and SourcePolicy.source_file_extension?(source_path) ->
        [Path.expand(source_path)]

      true ->
        []
    end
  end

  defp walk(root, dir, review_dir, source_blacklist) do
    if Path.expand(dir) == review_dir do
      []
    else
      dir
      |> File.ls!()
      |> Enum.flat_map(fn entry ->
        path = Path.join(dir, entry)

        cond do
          SourcePolicy.blacklisted_path?(root, path, source_blacklist) ->
            []

          File.dir?(path) ->
            walk(root, path, review_dir, source_blacklist)

          File.regular?(path) and SourcePolicy.source_file_extension?(path) ->
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
end
