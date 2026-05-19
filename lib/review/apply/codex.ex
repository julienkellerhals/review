defmodule Review.Apply.Codex do
  @moduledoc false

  alias Review.Common.Codex, as: CodexCLI
  alias Review.Apply.Prompts

  @default_apply_reasoning_effort "low"
  @default_review_reasoning_effort "medium"

  def apply_review(root, relative_review, source_file, previous_rejection, opts \\ []) do
    prompt = Prompts.apply_prompt(relative_review, source_file, previous_rejection)
    profile = Keyword.get(opts, :profile)

    case CodexCLI.exec(codex_apply_args(root, profile), prompt,
           prompt_prefix: "codex-review-apply-prompt"
         ) do
      {_, 0} -> :ok
      {_, status} -> abort("Failed applying #{relative_review}; codex exited with #{status}")
    end
  end

  def review_fix(root, relative_review, source_file, opts \\ []) do
    output_path = CodexCLI.tmp_markdown_path("codex-fix-review")
    profile = Keyword.get(opts, :profile)

    case CodexCLI.exec(
           codex_read_only_args(root, output_path, profile),
           Prompts.review_fix_prompt(relative_review, source_file),
           prompt_prefix: "codex-review-fix-prompt"
         ) do
      {_, 0} ->
        output = CodexCLI.read_and_remove(output_path)

        if String.trim(output) == Prompts.fix_approved() do
          :approved
        else
          {:rejected, output}
        end

      {_, status} ->
        File.rm(output_path)
        abort("Failed reviewing fix for #{relative_review}; codex exited with #{status}")
    end
  end

  def commit_message(root, relative_review, source_file, opts \\ []) do
    output_path = CodexCLI.tmp_markdown_path("codex-review-commit-message")
    profile = Keyword.get(opts, :profile)

    case CodexCLI.exec(
           codex_read_only_args(root, output_path, profile),
           Prompts.commit_message_prompt(relative_review, source_file),
           prompt_prefix: "codex-review-commit-message-prompt"
         ) do
      {_, 0} ->
        output_path
        |> CodexCLI.read_and_remove()
        |> commit_subject!()

      {_, status} ->
        File.rm(output_path)

        abort(
          "Failed generating commit message for #{relative_review}; codex exited with #{status}"
        )
    end
  end

  defp codex_apply_args(root, profile) do
    [
      "exec",
      "--cd",
      root,
      "--full-auto",
      "-"
    ]
    |> CodexCLI.runtime_args(
      profile: profile,
      reasoning_effort: apply_reasoning_effort(profile),
      fast_mode: apply_fast_mode(profile)
    )
  end

  defp codex_read_only_args(root, output_path, profile) do
    [
      "exec",
      "--cd",
      root,
      "--sandbox",
      "read-only",
      "--output-last-message",
      output_path,
      "-"
    ]
    |> CodexCLI.runtime_args(
      profile: profile,
      reasoning_effort: review_reasoning_effort(profile),
      fast_mode: review_fast_mode(profile)
    )
  end

  defp apply_reasoning_effort(profile) do
    Review.Common.Config.codex_reasoning_effort(profile,
      env: "CODEX_APPLY_REASONING_EFFORT",
      key: :codex_apply_reasoning_effort,
      default: @default_apply_reasoning_effort
    )
  end

  defp review_reasoning_effort(profile) do
    Review.Common.Config.codex_reasoning_effort(profile,
      env: "CODEX_REVIEW_REASONING_EFFORT",
      key: :codex_review_reasoning_effort,
      default: @default_review_reasoning_effort
    )
  end

  defp apply_fast_mode(profile) do
    Review.Common.Config.codex_fast_mode(profile,
      env: "CODEX_APPLY_FAST_MODE",
      key: :codex_apply_fast_mode
    )
  end

  defp review_fast_mode(profile) do
    Review.Common.Config.codex_fast_mode(profile,
      env: "CODEX_REVIEW_FAST_MODE",
      key: :codex_review_fast_mode
    )
  end

  defp commit_subject!(content) do
    subject =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "```")))
      |> List.first()

    if subject in [nil, ""] do
      abort("Codex did not generate a usable commit message")
    end

    subject
  end

  defp abort(message) do
    raise Review.Error, message
  end
end
