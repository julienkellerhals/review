defmodule Review.Generate.Codex do
  @moduledoc false

  alias Review.Common.Codex, as: CodexCLI
  alias Review.Generate.Prompts
  alias Review.Generate.ReviewDocument

  @default_reasoning_effort "high"

  def run_review(root, review_path, relative_source) do
    tmp_path = CodexCLI.tmp_markdown_path("codex-review")
    prompt = Prompts.review_prompt(relative_source, Review.Tools.Tooling.prompt_guidance(root))

    IO.puts("Reviewing #{relative_source}")

    case CodexCLI.exec(codex_review_args(root, tmp_path), prompt,
           prompt_prefix: "codex-review-generate-prompt"
         ) do
      {_, 0} ->
        ReviewDocument.write_actionable_review(tmp_path, review_path, relative_source)

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
    |> CodexCLI.runtime_args(codex_reasoning_effort())
  end

  defp codex_reasoning_effort do
    Review.Common.Env.string("CODEX_REASONING_EFFORT", @default_reasoning_effort)
  end
end
