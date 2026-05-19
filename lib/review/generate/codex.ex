defmodule Review.Generate.Codex do
  @moduledoc false

  alias Review.Common.Codex, as: CodexCLI
  alias Review.Generate.Prompts
  alias Review.Generate.ReviewDocument

  @default_reasoning_effort "high"

  def run_review(root, review_path, relative_source, opts \\ []) do
    tmp_path = CodexCLI.tmp_markdown_path("codex-review")
    prompt = Prompts.review_prompt(relative_source, Review.Tools.Tooling.prompt_guidance(root))
    log_path = review_log_path(review_path)
    session_path = review_session_path(review_path)
    session_id = resume_session_id(session_path, Keyword.get(opts, :resume, false))
    profile = Keyword.get(opts, :profile)

    if session_id do
      IO.puts("Resuming #{relative_source}")
    else
      IO.puts("Reviewing #{relative_source}")
    end

    case CodexCLI.exec(codex_review_args(root, tmp_path, session_id, profile), prompt,
           prompt_prefix: "codex-review-generate-prompt",
           log_path: log_path,
           session_path: session_path
         ) do
      {_, 0} ->
        ReviewDocument.write_actionable_review(tmp_path, review_path, relative_source)

      {_, status} ->
        File.rm(tmp_path)
        {:error, "Failed reviewing #{relative_source}; codex exited with #{status}"}
    end
  end

  defp codex_review_args(root, tmp_path, nil, profile) do
    [
      "exec",
      "--json",
      "--cd",
      root,
      "--sandbox",
      "read-only",
      "--output-last-message",
      tmp_path,
      "-"
    ]
    |> CodexCLI.runtime_args(
      profile: profile,
      reasoning_effort: codex_reasoning_effort(profile),
      fast_mode: codex_fast_mode(profile)
    )
  end

  defp codex_review_args(_root, tmp_path, session_id, profile) do
    [
      "exec",
      "resume",
      "--json",
      "--output-last-message",
      tmp_path,
      session_id,
      "-"
    ]
    |> CodexCLI.runtime_args(
      profile: profile,
      reasoning_effort: codex_reasoning_effort(profile),
      fast_mode: codex_fast_mode(profile)
    )
  end

  defp codex_reasoning_effort(profile) do
    Review.Common.Config.codex_reasoning_effort(profile,
      env: "CODEX_REASONING_EFFORT",
      key: :codex_reasoning_effort,
      default: @default_reasoning_effort
    )
  end

  defp codex_fast_mode(profile) do
    Review.Common.Config.codex_fast_mode(profile,
      env: "CODEX_FAST_MODE",
      key: :codex_fast_mode
    )
  end

  defp review_log_path(review_path) do
    Path.rootname(review_path) <> ".log"
  end

  defp review_session_path(review_path) do
    Path.rootname(review_path) <> ".session"
  end

  defp resume_session_id(_session_path, false), do: nil

  defp resume_session_id(session_path, true) do
    case File.read(session_path) do
      {:ok, content} ->
        content
        |> String.trim()
        |> empty_to_nil()

      {:error, _reason} ->
        nil
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
