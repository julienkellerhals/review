---
name: zoekt-code-search
description: Use Zoekt indexed code search when available to find references, duplicate text patterns, stale flags/prompts, and direct collaborators quickly in larger repositories.
---

# Zoekt Code Search

Use Zoekt as an indexed source-code search tool when a local index is available or the repo has documented Zoekt setup. It complements `rg`: use it for fast broad retrieval, then read the relevant files before making findings.

## Prerequisites

- CLI: `zoekt`.
- Indexer: `zoekt-index` for directories or `zoekt-git-index` for git repositories.
- Optional: Universal ctags for better symbol-aware ranking.
- Check availability with `mix review.tools` in repositories that use the review task.
- Build a local index with `mix review.zoekt.index` when Zoekt is installed and setup work is allowed.

## When To Use

- Find references to a symbol, config key, flag, prompt, route, module, or file name across a larger repo.
- Find duplicate adapters, stale workflow leftovers, or repeated literal patterns.
- Explore direct collaborators without scanning the whole repository manually.
- Compare search results across file filters or boolean queries.

## Workflow

1. Confirm a usable index exists, or use `mix review.zoekt.index` or repo-local documented commands to build one if setup work is allowed.
2. Query with the narrowest useful term and file filters.
3. Use Zoekt results as retrieval hints, not proof.
4. Read the relevant files and verify the finding in source before recommending a cleanup.
5. Fall back to `rg` when Zoekt is unavailable, stale, or not indexed for the current working tree.
