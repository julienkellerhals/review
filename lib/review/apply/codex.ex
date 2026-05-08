defmodule Review.Apply.Codex do
  @moduledoc false

  alias Review.Common.Codex, as: CodexCLI
  alias Review.Apply.Prompts

  @default_apply_reasoning_effort "low"
  @default_review_reasoning_effort "medium"

  def apply_review(root, relative_review, source_file, previous_rejection) do
    prompt = Prompts.apply_prompt(relative_review, source_file, previous_rejection)

    case CodexCLI.exec(codex_apply_args(root), prompt, prompt_prefix: "codex-review-apply-prompt") do
      {_, 0} -> :ok
      {_, status} -> abort("Failed applying #{relative_review}; codex exited with #{status}")
    end
  end

  def review_fix(root, relative_review, source_file) do
    output_path = CodexCLI.tmp_markdown_path("codex-fix-review")

    case CodexCLI.exec(
           codex_read_only_args(root, output_path),
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

  def commit_message(root, relative_review, source_file) do
    output_path = CodexCLI.tmp_markdown_path("codex-review-commit-message")

    case CodexCLI.exec(
           codex_read_only_args(root, output_path),
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

  defp codex_apply_args(root) do
    [
      "exec",
      "--cd",
      root,
      "--full-auto",
      "-"
    ]
    |> CodexCLI.runtime_args(apply_reasoning_effort())
  end

  defp codex_read_only_args(root, output_path) do
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
    |> CodexCLI.runtime_args(review_reasoning_effort())
  end

  defp apply_reasoning_effort do
    Review.Common.Env.string(
      "CODEX_APPLY_REASONING_EFFORT",
      Review.Common.Env.string("CODEX_REASONING_EFFORT", @default_apply_reasoning_effort)
    )
  end

  defp review_reasoning_effort do
    Review.Common.Env.string(
      "CODEX_REVIEW_REASONING_EFFORT",
      Review.Common.Env.string("CODEX_REASONING_EFFORT", @default_review_reasoning_effort)
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
