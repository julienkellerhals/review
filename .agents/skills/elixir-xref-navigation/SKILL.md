---
name: elixir-xref-navigation
description: Use Mix xref in Elixir projects to inspect compile/runtime/export dependencies, callers, and dependency direction before proposing or applying structural refactors.
---

# Elixir Xref Navigation

Use `mix xref` when reviewing or changing Elixir code and the recommendation depends on dependency direction, caller impact, or module coupling.

## Prerequisites

- A project root with `mix.exs`.
- The `mix` executable on `PATH`.
- Project dependencies installed when the xref query needs compilation.
- Check availability with `mix review.tools` in repositories that use the review task.

## When To Use

- Identify who calls a module or function before recommending a move, rename, merge, or deletion.
- Check whether a dependency points in the wrong direction.
- Find compile-time coupling that makes modules harder to test or move.
- Validate that a boundary refactor will not create circular or broader dependencies.

## Useful Commands

- `mix xref callers Module.Name`
- `mix xref graph --label compile`
- `mix xref graph --label runtime`
- `mix xref graph --source lib/path/to/file.ex`
- `mix xref graph --sink lib/path/to/file.ex`
- `mix xref warnings`

## Workflow

1. Confirm the project is Elixir by checking for `mix.exs`.
2. Use the narrowest `mix xref` command that answers the dependency question.
3. Read the relevant modules after inspecting xref output.
4. Include xref-backed dependency evidence in findings when it materially changes the recommendation.
5. If `mix xref` cannot run because dependencies are missing or the project does not compile, fall back to source search and mention the verification gap.
