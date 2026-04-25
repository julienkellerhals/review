defmodule Review.Generate do
  @default_concurrency 10
  @default_recommendation_limit 20
  @default_model "gpt-5.5"
  @default_reasoning_effort "high"
  alias Review.SourcePolicy

  def main(["-h"]), do: usage()
  def main(["--help"]), do: usage()

  def main(args) do
    root = repo_root()
    review_dir = review_dir(root)
    concurrency = review_concurrency()
    source_blacklist = SourcePolicy.source_blacklist()
    source_dirs = Review.Config.source_dirs()
    File.mkdir_p!(review_dir)

    root
    |> files_to_review(args, review_dir, source_blacklist, source_dirs)
    |> review_files(root, review_dir, concurrency)
  end

  defp usage do
    IO.puts("Usage: mix review.generate [path/to/source-file ...]")

    IO.puts(
      "Without explicit files, supported source files under non-ignored folders are reviewed."
    )

    IO.puts("Explicit file arguments must be under this repository.")
    IO.puts(~s(Configure default discovery with `config :review, source_dirs: ["lib", "test"]`.))
    IO.puts("Set REVIEW_DIR to choose the output directory. Defaults to review.")
    IO.puts("Set REVIEW_CONCURRENCY to choose parallel Codex execs. Defaults to 10.")

    IO.puts(
      "Set REVIEW_SOURCE_BLACKLIST to comma-separated source folder names to exclude. Bare names and **/name/ both match any path segment."
    )

    IO.puts(
      "Set REVIEW_RECOMMENDATION_LIMIT to cap recommendations per generated review. Defaults to 20."
    )

    IO.puts("Set CODEX_MODEL to override the Codex model. Defaults to gpt-5.5.")
    IO.puts("Set CODEX_REASONING_EFFORT to override the reasoning effort. Defaults to high.")
  end

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> root |> String.trim() |> Path.expand()
      _ -> File.cwd!()
    end
  end

  defp review_dir(root) do
    Review.Config.review_dir(root)
  end

  defp review_concurrency do
    "REVIEW_CONCURRENCY"
    |> System.get_env(Integer.to_string(@default_concurrency))
    |> parse_positive_integer!("REVIEW_CONCURRENCY")
  end

  defp recommendation_limit do
    "REVIEW_RECOMMENDATION_LIMIT"
    |> System.get_env(Integer.to_string(@default_recommendation_limit))
    |> parse_positive_integer!("REVIEW_RECOMMENDATION_LIMIT")
  end

  defp parse_positive_integer!(value, name) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> abort("Expected #{name} to be a positive integer, got: #{inspect(value)}")
    end
  end

  defp files_to_review(root, [], review_dir, source_blacklist, source_dirs) do
    root
    |> discover_source_files(review_dir, source_blacklist, source_dirs)
    |> Enum.sort()
  end

  defp files_to_review(root, args, _review_dir, source_blacklist, _source_dirs) do
    Enum.map(args, &validate_source_file!(root, &1, source_blacklist))
  end

  defp validate_source_file!(root, path, source_blacklist) do
    source = Path.expand(path, root)

    cond do
      not under_repo_root?(root, source) ->
        abort("Expected a file under #{root}, got: #{source}")

      SourcePolicy.blacklisted_path?(root, source, source_blacklist) ->
        abort("Expected an existing supported source file, got: #{source}")

      not File.regular?(source) or not SourcePolicy.source_file_extension?(source) ->
        abort("Expected an existing supported source file, got: #{source}")

      true ->
        source
    end
  end

  def discover_source_files(
        root,
        review_dir,
        source_blacklist,
        source_dirs \\ Review.Config.source_dirs()
      ) do
    root = Path.expand(root)
    review_dir = Path.expand(review_dir, root)

    source_dirs
    |> Enum.flat_map(&discover_source_path(root, &1, review_dir, source_blacklist))
    |> Enum.uniq()
  end

  defp discover_source_path(root, source_dir, review_dir, source_blacklist) do
    source_path = Path.expand(source_dir, root)

    cond do
      not under_repo_root?(root, source_path) ->
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

  defp under_repo_root?(root, path) do
    path == root or String.starts_with?(path, root <> "/")
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
    review_file(root, review_dir, source)
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

    abort(message)
  end

  defp review_file(root, review_dir, source) do
    relative_source = Path.relative_to(source, root)
    review_path = Path.join([review_dir, relative_source, "review.md"])

    if File.regular?(review_path) do
      IO.puts("Skipping #{relative_source}: review already exists")
      :ok
    else
      run_review(root, review_path, relative_source)
    end
  end

  defp run_review(root, review_path, relative_source) do
    tmp_path = tmp_path("codex-review", "md")
    prompt = review_prompt(relative_source, recommendation_limit())

    IO.puts("Reviewing #{relative_source}")

    case run_codex(codex_review_args(root, tmp_path), prompt) do
      {_, 0} ->
        write_actionable_review(tmp_path, review_path, relative_source)

      {_, status} ->
        File.rm(tmp_path)
        {:error, "Failed reviewing #{relative_source}; codex exited with #{status}"}
    end
  end

  defp codex_review_args(root, tmp_path) do
    [
      "exec",
      "--cd",
      root,
      "--sandbox",
      "read-only",
      "--output-last-message",
      tmp_path,
      "-"
    ]
    |> add_model()
  end

  defp add_model(args) do
    [
      "--config",
      "model_reasoning_effort=#{codex_reasoning_effort()}",
      "--model",
      codex_model()
      | args
    ]
  end

  defp codex_model do
    env_or_default("CODEX_MODEL", @default_model)
  end

  defp codex_reasoning_effort do
    env_or_default("CODEX_REASONING_EFFORT", @default_reasoning_effort)
  end

  defp env_or_default(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  defp run_codex(args, prompt) do
    prompt_path = tmp_path("codex-review-prompt", "md")
    File.write!(prompt_path, prompt)

    result =
      System.cmd(
        "sh",
        [
          "-c",
          "prompt_path=$1; shift; \"$@\" < \"$prompt_path\"",
          "codex-stdin",
          prompt_path,
          "codex" | args
        ],
        stderr_to_stdout: true
      )

    File.rm(prompt_path)
    maybe_report_failed_log(result)
    result
  end

  defp maybe_report_failed_log({_output, 0}), do: :ok

  defp maybe_report_failed_log({output, _status}) do
    IO.puts(:stderr, "Codex log:")
    IO.puts(:stderr, output)
  end

  defp review_prompt(relative_source, recommendation_limit) do
    """
    Review `#{relative_source}` for maintenance pruning after iterative AI coding.

    Use:
    - improve-codebase-architecture: find shallow modules, tight coupling, duplicated orchestration, and deeper boundaries.
    - design-an-interface when the best cleanup depends on comparing alternate module/API/file boundaries.
    - request-refactor-plan methods: order risky cleanup in small reversible steps with tests.
    - use-igniter when a mechanical Elixir rename/move/remove would be safer than hand edits.
    - AGENTS.md plus relevant language/framework docs only if this file touches those layers.

    Scope: this file plus direct collaborators only. Do not scan the whole repo.
    Bias: delete, merge, simplify, move files, or shrink public surface before adding abstractions.
    Look for: dead code, stale flags/options/prompts, unused Codex or agent workflow leftovers, duplicate adapters, brittle seams, and tests that only preserve shallow structure.
    You may recommend moving/renaming files or reshaping directories when a clearer structure would reduce coupling.

    Return at most #{recommendation_limit} concrete cleanup recommendations with focused verification.

    Rules:
    - Do not edit files.
    - If nothing is worth pruning, output exactly:
    NO_ACTIONABLE_REVIEW
    - Otherwise output markdown only:
    - Start actionable markdown with `# Review: #{relative_source}`.
    - Put this metadata block immediately after the title, exactly in this format:
    Source file: `#{relative_source}`
    Affected files:
    - `#{relative_source}`
    - `path/to/other_file.ext`
    - Use repo-relative paths only. Do not use markdown links, absolute paths, inline comma-separated lists, or put file names on the `Affected files:` line.
    - Include every file the implementation is expected to edit, move, or delete. Include `#{relative_source}` at minimum.
    - Use only these sections: Overview, Findings, Recommendations, Verification.
    - Findings must name concrete files/functions and the maintenance risk.
    """
  end

  defp tmp_path(prefix, extension) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.#{extension}")
  end

  defp write_actionable_review(tmp_path, review_path, relative_source) do
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

  defp abort(message) do
    raise Review.Error, message
  end
end
