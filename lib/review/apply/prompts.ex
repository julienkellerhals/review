defmodule Review.Apply.Prompts do
  @moduledoc false

  @fix_approved "FIX_APPROVED"

  def fix_approved, do: @fix_approved

  def apply_prompt(relative_review, source_file, nil) do
    case Path.extname(source_file) do
      ".py" ->
        python_apply_prompt(relative_review, source_file)

      ext when ext in [".ex", ".exs", ".heex"] ->
        elixir_apply_prompt(relative_review, source_file)

      _ ->
        generic_apply_prompt(relative_review, source_file)
    end
  end

  def apply_prompt(relative_review, source_file, previous_rejection) do
    """
    A read-only review of the previous fix rejected it. Continue from the current working tree and implement the blocking issues below.

    Previous fix review output:
    #{String.trim(previous_rejection)}

    #{apply_prompt(relative_review, source_file, nil)}
    """
  end

  def review_fix_prompt(relative_review, source_file) do
    """
    Perform a read-only gate review of the current working tree against `#{relative_review}`.
    Primary file: `#{source_file}`.

    Decision criteria:
    - Do not edit files.
    - Read the review markdown and inspect the working tree diff.
    - Approve only if the diff implements the review's concrete recommendations without unsafe scope creep.
    - Require focused tests or a clear verification path for changed behavior.
    - Ignore unrelated pre-existing dirty files that are not part of this review.
    - Reject stale, partial, risky, or unverified fixes with specific blocking issues.

    Output:
    - If the fix satisfies the review, output exactly:
    #{@fix_approved}
    - Otherwise output markdown starting with:
    FIX_REJECTED
    - After FIX_REJECTED, list only the blocking issues the fixing agent must address.
    """
  end

  def commit_message_prompt(relative_review, source_file) do
    """
    Generate a git commit subject for the working tree changes that apply `#{relative_review}`.
    The primary source file is `#{source_file}`.

    Instructions:
    - Read the review markdown and inspect the working tree diff.
    - Output only one concise commit subject line.
    - Do not use markdown, code fences, bullet points, quotes, or a trailing period.
    - Do not run git commands that modify the index or create commits.
    """
  end

  defp elixir_apply_prompt(relative_review, source_file) do
    apply_prompt_template(
      relative_review,
      source_file,
      """
      - Respect AGENTS.md and dependency usage rules; use `mix usage_rules.docs` or `mix usage_rules.search_docs` when changing framework or dependency APIs.
      - If a mechanical Elixir rename, move, create, or delete is the safest cleanup path, use `use-igniter` instead of hand edits.
      """
    )
  end

  defp python_apply_prompt(relative_review, source_file) do
    apply_prompt_template(
      relative_review,
      source_file,
      """
      - Respect AGENTS.md, README.md, pyproject.toml, and the existing Python/Airflow patterns.
      - Run the narrow relevant checks you can, such as `uv run ruff check airflow/dags airflow/tests`, `uv run ty check airflow/dags`, or focused `uv run python -m unittest ...` commands.
      """
    )
  end

  defp generic_apply_prompt(relative_review, source_file) do
    apply_prompt_template(
      relative_review,
      source_file,
      """
      - Respect AGENTS.md, README.md, package manifests, and the existing language/framework patterns.
      """
    )
  end

  defp apply_prompt_template(relative_review, source_file, language_guidance) do
    language_guidance = String.trim(language_guidance)

    """
    Implement the concrete cleanup recommendations in `#{relative_review}`.
    Primary file: `#{source_file}`.

    Success criteria:
    - Read the review and directly relevant code before editing.
    - Keep the change focused on the review; leave unrelated dirty files and unrelated refactors alone.
    - Prefer the smallest cohesive refactor that satisfies the recommendation.
    - Move, rename, create, or delete files only when the review calls for structural cleanup or it clearly reduces coupling.
    - If a recommendation is stale, unsafe, or no longer applies, do not force it; explain why in the final response.
    - Add or update focused tests when behavior changes, and run the narrow relevant checks you can.

    Tooling and local rules:
    - Use the improve-codebase-architecture skill.
    - Use design-an-interface only if the review depends on choosing a better API, module, or file boundary.
    #{language_guidance}

    Safety:
    - Do not run git add, git commit, or delete the review markdown. The script will review, delete, stage, and commit after you finish.
    """
  end
end
