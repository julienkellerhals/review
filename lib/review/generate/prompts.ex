defmodule Review.Generate.Prompts do
  @moduledoc false

  def review_prompt(relative_source, tooling_guidance) do
    """
    Review `#{relative_source}` for high-value maintenance cleanup after iterative AI coding.
    Do not edit files.

    #{tooling_guidance}

    Outcome:
    - Exhaustively report every high-confidence actionable finding inside the review scope.
    - Do not stop after a fixed number of findings.
    - Prefer deletion, merging, simplification, moves, or public-surface reduction before new abstractions.
    - Skip speculative, cosmetic, or low-value cleanup. If nothing is worth applying, output exactly:
    NO_ACTIONABLE_REVIEW

    Review scope:
    - Inspect `#{relative_source}` and only direct collaborators needed to judge it.
    - Do not scan the whole repo.
    - Look for dead code, stale flags/options/prompts, unused Codex or agent workflow leftovers, duplicate adapters, brittle boundaries, and tests that preserve shallow structure without behavior.
    - Recommend moving, renaming, or reshaping files only when it clearly reduces coupling or clarifies ownership.

    Tooling:
    - Use the improve-codebase-architecture skill to identify shallow modules, tight coupling, duplicated orchestration, and better boundaries.
    - Use the design-an-interface skill only when the recommendation depends on choosing between API, module, or file-boundary options.
    - Use the zoekt-code-search skill when indexed source search is available and broader reference or duplicate-pattern search would help.
    - Use the ast-grep-code-search skill when syntax-aware search would find structural duplicates or API usage more reliably than text search.
    - Use the elixir-xref-navigation skill in Elixir projects when dependency direction, callers, or compile/runtime coupling matter.
    - Use the scip-code-intelligence skill when a repo-local SCIP index or query tool is already available for precise definitions and references.
    - Use AGENTS.md and relevant language/framework docs only if this file touches those layers.
    - Mention use-igniter in the recommendation or verification when a mechanical Elixir rename, move, or removal would be safer than hand edits.
    - Treat search, xref, and index output as navigation evidence; read the relevant files before making findings.

    Markdown output:
    - Output markdown only unless returning NO_ACTIONABLE_REVIEW.
    - Start actionable markdown with `# Review: #{relative_source}`.
    - Put this metadata block immediately after the title, exactly:
    Source file: `#{relative_source}`
    Affected files:
    - `#{relative_source}`
    - `path/to/other_file.ext`
    - Use repo-relative affected-file paths only. Do not use markdown links, absolute paths, inline comma-separated lists, or file names on the `Affected files:` line.
    - Include every file the implementation is expected to edit, move, or delete; include `#{relative_source}` at minimum.
    - Use exactly these sections: Overview, Findings, Recommendations, Verification.
    - Findings must name concrete files/functions and the maintenance risk.
    - Recommendations must state the exact cleanup, why it is worth doing, and any ordering needed to keep the change safe.
    - Verification must list focused tests or checks for the cleanup.
    """
  end
end
