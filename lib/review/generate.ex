defmodule Review.Generate do
  @default_concurrency 10

  alias Review.Generate.ReviewFile
  alias Review.Generate.SourceSet
  alias Review.Common.SourcePolicy

  def main(["-h"]), do: usage()
  def main(["--help"]), do: usage()

  def main(args) do
    runtime = Review.Common.Runtime.from_args!(args, mode: :generate)
    root = runtime.root
    review_dir = runtime.review_dir
    concurrency = review_concurrency()
    source_policy = runtime.source_policy
    source_dirs = source_policy.source_dirs
    File.mkdir_p!(review_dir)

    files = SourceSet.files(root, runtime.args, review_dir, source_policy, source_dirs)
    Review.Tools.Tooling.maybe_report(root)

    review_files(files, root, review_dir, concurrency)
  end

  def discover_source_files(
        root,
        review_dir,
        source_policy_or_blacklist,
        source_dirs \\ Review.Common.Config.source_dirs()
      ) do
    source_policy = normalize_source_policy(source_policy_or_blacklist, source_dirs)

    SourceSet.discover_source_files(root, review_dir, source_policy, source_dirs)
  end

  defp usage do
    IO.puts("Usage: mix review.generate [path/to/source-file ...]")
    IO.puts("       mix review.generate --profile PROFILE [path/to/source-file ...]")

    IO.puts(
      "Without explicit files, supported source files under non-ignored folders are reviewed."
    )

    IO.puts("Explicit file arguments must be under this repository.")

    IO.puts(
      ~s(Configure default discovery with `config :review, source_dirs: ["lib", "test"], source_dirs_mode: :whitelist, source_file_extensions: [".ex", ".exs"], source_blacklist: ["deps"]`.)
    )

    IO.puts("Set REVIEW_DIR to choose the output directory. Defaults to review.")
    IO.puts("Set REVIEW_CONCURRENCY to choose parallel Codex execs. Defaults to 10.")

    IO.puts(
      "Set REVIEW_SOURCE_BLACKLIST to comma-separated source folder names to exclude. Bare names and **/name/ both match any path segment."
    )

    IO.puts("Set CODEX_MODEL to override the Codex model. Defaults to gpt-5.5.")
    IO.puts("Set CODEX_REASONING_EFFORT to override the reasoning effort. Defaults to high.")
  end

  defp review_concurrency do
    Review.Common.Env.positive_integer("REVIEW_CONCURRENCY", @default_concurrency)
  end

  defp review_files(files, root, review_dir, concurrency) do
    IO.puts("Reviewing #{length(files)} file(s) with up to #{concurrency} concurrent Codex execs")

    failures =
      files
      |> Task.async_stream(&safe_review_file(root, review_dir, &1),
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce([], &collect_review_result/2)

    case failures do
      [] ->
        :ok

      failures ->
        failures
        |> Enum.reverse()
        |> report_review_failures()
    end
  end

  defp safe_review_file(root, review_dir, source) do
    ReviewFile.review(root, review_dir, source)
  rescue
    exception ->
      relative_source = Path.relative_to(source, root)
      {:error, "Failed reviewing #{relative_source}: #{Exception.message(exception)}"}
  catch
    kind, reason ->
      relative_source = Path.relative_to(source, root)
      {:error, "Failed reviewing #{relative_source}: #{kind} #{inspect(reason)}"}
  end

  defp collect_review_result({:ok, :ok}, failures), do: failures

  defp collect_review_result({:ok, {:error, message}}, failures) do
    [message | failures]
  end

  defp collect_review_result({:exit, reason}, failures) do
    ["Review task exited: #{inspect(reason)}" | failures]
  end

  defp report_review_failures(failures) do
    message =
      [
        "#{length(failures)} review(s) failed:",
        Enum.map_join(failures, "\n", &("- " <> &1))
      ]
      |> Enum.join("\n")

    raise Review.Error, message
  end

  defp normalize_source_policy(%{} = source_policy, _source_dirs), do: source_policy

  defp normalize_source_policy(blacklist, source_dirs) when is_list(blacklist) do
    %SourcePolicy{
      blacklist: blacklist,
      extensions: Review.Common.Config.source_file_extensions(),
      source_dirs: source_dirs,
      source_dirs_mode: :discover
    }
  end
end
