# Review

Standalone Mix tasks for Codex-driven review workflows.

## Tasks

```sh
mix review.generate [path/to/source-file ...]
mix review.apply [review|path/to/review.md]
mix review.cleanup_worktrees
```

The tasks are intended to run from the target repository root. They keep the
same environment variables as the original scripts, including `REVIEW_DIR`,
`REVIEW_SOURCE_BLACKLIST`, `CODEX_MODEL`, and the task-specific concurrency and
retry settings.

By default, `mix review.generate` searches the whole repository except ignored
folders. Configure the default source roots in the consuming project's
`config/config.exs`:

```elixir
import Config

config :review,
  source_dirs: ["lib", "test", "config", "priv", "assets"]
```

`source_dirs` entries must be repo-relative directories or files. Explicit file
arguments passed to `mix review.generate path/to/file.ex` are still honored even
when they are outside the configured default discovery roots.

Failures are reported as Mix task errors with the underlying command, file, or
review path included. The library code raises `Review.Error` for expected
operational failures and does not call `System.halt/1`, so test runs and parent
Mix processes keep control of error reporting.

## Add To Another Mix Project

For a local checkout:

```elixir
def deps do
  [
    {:review, path: "/home/julienk/Documents/projects/review", only: [:dev, :test], runtime: false}
  ]
end
```

After `mix deps.get`, run the tasks from the consuming project:

```sh
mix review.generate
mix review.apply
mix review.cleanup_worktrees
```
