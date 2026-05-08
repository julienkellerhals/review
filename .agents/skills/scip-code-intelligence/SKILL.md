---
name: scip-code-intelligence
description: Use SCIP indexes when available for precise code-intelligence lookups such as definitions, references, implementations, and symbol relationships across larger or multi-language repositories.
---

# SCIP Code Intelligence

Use SCIP only when a SCIP index or repo-local SCIP tooling is already available. It is a precise code-intelligence layer, not a default setup requirement.

## Prerequisites

- A repo-local index such as `index.scip` or `.scip/`, or documented repo-local SCIP commands.
- Optional CLIs: `scip`, `src`, `scip-typescript`, `scip-python`, or another project-appropriate SCIP indexer.
- Common indexer installs include `npm install -g @sourcegraph/scip-typescript` and `npm install -g @sourcegraph/scip-python`.
- Check availability with `mix review.tools` in repositories that use the review task.

## When To Use

- Find references or definitions more precisely than text search can.
- Understand cross-file symbol relationships in large repositories.
- Check implementation impact before recommending API, module, or file-boundary changes.
- Validate that all direct callers of a symbol were considered.

## Workflow

1. Look for repo-local SCIP evidence such as `index.scip`, `.scip/`, `scip-*` scripts, or documented index commands.
2. Use the existing repo command or tool to query definitions/references when available.
3. Treat SCIP results as navigation help. Read the files that matter before making a finding.
4. If no index or query tool exists, do not set one up during a review unless the user explicitly asks. Fall back to `rg`, Zoekt, ast-grep, or language-native tooling.

## Boundaries

- Do not download indexers or build a new index during a read-only review unless the task explicitly permits setup work.
- Do not rely on stale indexes without checking whether the relevant files changed.
- Prefer language-native tools such as `mix xref` for Elixir dependency direction when they answer the question directly.
