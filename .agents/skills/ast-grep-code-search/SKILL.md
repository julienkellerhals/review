---
name: ast-grep-code-search
description: Use ast-grep for syntax-aware code search when text search is too broad or when a review needs to find structural patterns, repeated code shapes, API call forms, or language-aware matches across supported source files.
---

# Ast-Grep Code Search

Use `ast-grep` (`sg`) as a syntax-aware search tool. It complements `rg` and indexed text search: use it when the shape of code matters more than an exact string.

## Prerequisites

- CLI: `sg` or `ast-grep`.
- Typical install options: `npm install -g @ast-grep/cli`, `cargo install ast-grep`, or an OS package when available.
- Check availability with `mix review.tools` in repositories that use the review task.

## When To Use

- Find repeated structural patterns such as similar `case`, `if`, `with`, class, function, import, or call shapes.
- Find old API usage where variable names differ but the AST shape is stable.
- Compare wrapper modules, duplicate adapters, or shallow delegation patterns.
- Validate that a proposed cleanup affects all matching code shapes in the review scope.

Use plain `rg` or Zoekt first when a literal text query is enough.

## Workflow

1. Identify the language and the smallest useful search scope.
2. Run `sg --lang <language> --pattern '<pattern>' <paths...>` when `sg` is available.
3. Read the matching files before making a finding. Treat matches as leads, not proof.
4. If `sg` is unavailable or the language is unsupported, fall back to `rg` and explain the fallback only if it affects confidence.

## Pattern Notes

- Prefer precise patterns over broad wildcards.
- Use metavariables for names or expressions that vary.
- Keep searches scoped to direct collaborators unless the task explicitly calls for a broader repo sweep.
- Do not run rewrite commands unless explicitly asked to implement a change.
