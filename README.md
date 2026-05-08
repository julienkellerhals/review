# Review

Standalone Mix tasks for Codex-driven review workflows.

## Tasks

```sh
mix review.generate [path/to/source-file ...]
mix review.apply [review|path/to/review.md]
mix review.tools
mix review.zoekt.index
mix review.cleanup_worktrees
```

Mix task documentation follows normal Elixir conventions:

```sh
mix help review.generate
mix help review.apply
mix help review.tools
mix help review.zoekt.index
mix help review.cleanup_worktrees
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
  review_dir: "review",
  source_dirs: ["lib", "test", "config", "priv", "assets"],
  source_dirs_mode: :discover,
  source_file_extensions: [".ex", ".exs", ".heex", ".js", ".ts"],
  source_blacklist: [".git", "_build", "deps", "node_modules"]
```

`review_dir` controls where markdown files are written. `source_dirs` entries
must be repo-relative directories or files. With the default
`source_dirs_mode: :discover`, they only control default discovery; explicit file
arguments can still point outside those roots. With
`source_dirs_mode: :whitelist`, they also become an allow-list for explicit
generation and apply validation. `source_file_extensions` controls which file
extensions are reviewable. `source_blacklist` controls ignored folder names;
`REVIEW_SOURCE_BLACKLIST` can still override it for one run.

Profiles let one repository hold different review configs for subprojects:

```elixir
config :review,
  profiles: [
    one: [
      root: "apps/one",
      review_dir: "reviews",
      source_dirs: ["lib", "test"],
      source_dirs_mode: :whitelist
    ],
    two: [
      root: "apps/two",
      review_dir: "reviews",
      source_dirs: ["src"],
      source_file_extensions: [".py"]
    ]
  ]
```

Select a profile with `--profile one`. Without `--profile`, the tasks use a
`:default` profile when configured, otherwise the top-level `config :review`
values.

## Optional Review Tooling

`mix review.generate` checks optional navigation tools before running. Missing
tools do not fail the review; they only reduce what the generated review agent
can use. Set `REVIEW_TOOL_CHECK=0` to skip this report.

Run the checker directly with:

```sh
mix review.tools
mix review.tools --install
```

`mix review.tools --install` detects the current operating system before
printing commands. On Linux it reads `/etc/os-release` and uses the distro ID
and version, so Fedora/RHEL/CentOS get `dnf` guidance, Debian/Ubuntu get `apt`
guidance, Arch gets `pacman` guidance, and macOS gets Homebrew guidance. Unknown
systems get generic package-manager instructions.

Recommended optional tools:

- `rg`: baseline fast text search. Install with your OS package manager, for
  example `dnf install ripgrep`, `apt install ripgrep`, or `brew install ripgrep`.
- `ast-grep`: syntax-aware structural search used by the
  `ast-grep-code-search` skill. Install with `npm install -g @ast-grep/cli`,
  `cargo install ast-grep`, or your OS package manager when available.
- Zoekt: indexed source search for larger repositories used by the
  `zoekt-code-search` skill. Install the command-line tools with Go, for
  example:

  ```sh
  go install github.com/sourcegraph/zoekt/cmd/zoekt@latest
  go install github.com/sourcegraph/zoekt/cmd/zoekt-index@latest
  go install github.com/sourcegraph/zoekt/cmd/zoekt-git-index@latest
  ```

  Universal ctags is also useful because Zoekt can use symbol information for
  ranking. After installing Zoekt, build a local index for the current checkout
  with:

  ```sh
  mix review.zoekt.index
  ```

  This task uses `zoekt-index` by default so the index reflects the working
  tree. It does not clone repositories and does not install or vendor Zoekt.
  Use `mix review.zoekt.index --mode git` only when you specifically want
  `zoekt-git-index` behavior.
- Elixir `mix xref`: available automatically in Elixir projects when `mix` is
  installed. The `elixir-xref-navigation` skill uses it for callers,
  dependency direction, and compile/runtime coupling.
- SCIP: optional precise code intelligence. Install or use repo-local indexers
  only when the project already benefits from SCIP indexes. Common indexers
  include `npm install -g @sourcegraph/scip-typescript` for TypeScript/JavaScript
  and `npm install -g @sourcegraph/scip-python` for Python. The generic `scip`
  CLI can inspect SCIP indexes, and the checker looks for `index.scip` or
  `.scip/` in the repository.

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
mix review.tools
mix review.zoekt.index
mix review.cleanup_worktrees
```
