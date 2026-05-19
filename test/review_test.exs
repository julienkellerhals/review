defmodule ReviewTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "apply prompts expose shared workflow guidance" do
    prompt = Review.Apply.apply_prompt("review/foo/review.md", "lib/foo.ex", nil)

    assert prompt =~ "Use the improve-codebase-architecture skill."
    assert prompt =~ "Use design-an-interface"
    assert prompt =~ "mix usage_rules.docs"
  end

  test "conflicting review jobs are split into separate batches" do
    jobs = [
      %{relative_review: "one/review.md", affected_files: ["lib/foo.ex"]},
      %{relative_review: "two/review.md", affected_files: ["lib/foo.ex"]},
      %{relative_review: "three/review.md", affected_files: ["lib/bar.ex"]}
    ]

    assert [[first, third], [second]] = Review.Apply.plan_review_batches(jobs, 10)
    assert first.relative_review == "one/review.md"
    assert third.relative_review == "three/review.md"
    assert second.relative_review == "two/review.md"
  end

  test "apply terminal output renders a compact run summary" do
    jobs = [
      %{relative_review: "review/lib/foo.ex/review.md", affected_files: ["lib/foo.ex"]}
    ]

    output =
      capture_io(fn ->
        Review.Apply.Terminal.plan(1, 1, 4)
        Review.Apply.Terminal.batch_start(1, 1, jobs, 4)
        Review.Apply.Terminal.committed("review/lib/foo.ex/review.md", "Apply review")
      end)

    assert output =~ "Review apply"
    assert output =~ "reviews"
    assert output =~ "[batch 1/1] 1 review(s) | 1 agent(s)"
    assert output =~ "review/lib/foo.ex/review.md"
    assert output =~ "[ok] committed"
  end

  test "apply skips reviews that affect files outside the current repo" do
    root = tmp_dir("outside-affected-files")

    run!(root, "git", ["init"])
    write_file!(root, "lib/foo.ex")
    run!(root, "git", ["add", "lib/foo.ex"])

    run!(root, "git", [
      "-c",
      "user.email=test@example.com",
      "-c",
      "user.name=Test",
      "commit",
      "-m",
      "init"
    ])

    write_file!(
      root,
      "review/lib/foo.ex/review.md",
      """
      # Review: lib/foo.ex
      Source file: `lib/foo.ex`
      Affected files:
      - `lib/foo.ex`
      - `../sibling/bar.ex`

      ## Overview
      Update both files.
      """
    )

    in_dir(root, fn ->
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Review.Apply.main(["review"])
        end)

      assert output =~
               "Affected file escapes the repository root for review/lib/foo.ex/review.md: ../sibling/bar.ex"

      assert output =~ "No applicable reviews left after skipping review files"
      assert File.exists?(Path.join(root, "review/lib/foo.ex/review.md"))
    end)
  end

  test "fix review sees new files created by the apply attempt" do
    root = tmp_dir("fix-review-new-files")
    bin_dir = tmp_dir("fake-codex-bin")
    codex_path = Path.join(bin_dir, "codex")

    run!(root, "git", ["init"])
    run!(root, "git", ["config", "user.email", "test@example.com"])
    run!(root, "git", ["config", "user.name", "Test"])
    write_file!(root, "lib/source.ex")
    run!(root, "git", ["add", "lib/source.ex"])
    run!(root, "git", ["commit", "-m", "init"])

    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    args="$*"
    root=""
    output=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cd)
          shift
          root="$1"
          ;;
        --output-last-message)
          shift
          output="$1"
          ;;
      esac

      shift
    done

    prompt=$(cat)
    printf '%s\\n' "$args" >> "$root/codex_args.log"

    if [ -z "$output" ]; then
      mkdir -p "$root/lib"
      printf 'new coverage\\n' > "$root/lib/new_test.ex"
      exit 0
    fi

    if printf '%s' "$prompt" | grep -q "Generate a git commit subject"; then
      printf 'Add split test coverage\\n' > "$output"
      exit 0
    fi

    if git -C "$root" diff -- lib/new_test.ex | grep -q "new file mode"; then
      printf 'FIX_APPROVED\\n' > "$output"
    else
      {
        printf 'FIX_REJECTED\\n'
        printf -- '- new file was not visible in git diff\\n'
      } > "$output"
    fi
    """)

    File.chmod!(codex_path, 0o755)

    write_file!(
      root,
      "review/lib/source.ex/review.md",
      """
      # Review: lib/source.ex
      Source file: `lib/source.ex`
      Affected files:
      - `lib/source.ex`
      - `lib/new_test.ex`

      ## Overview
      Add split test coverage.
      """
    )

    previous_path = System.get_env("PATH")
    previous_attempts = System.get_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS")

    try do
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
      System.put_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS", "1")

      in_dir(root, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Review.Apply.main(["review"])
        end)
      end)

      assert File.exists?(Path.join(root, "lib/new_test.ex"))
      refute File.exists?(Path.join(root, "review/lib/source.ex/review.md"))

      codex_args = File.read!(Path.join(root, "codex_args.log"))
      assert codex_args =~ "model_reasoning_effort=low"
      assert codex_args =~ "model_reasoning_effort=medium"

      assert root
             |> git_output!(["show", "--name-only", "--format=%s", "HEAD"])
             |> String.contains?("lib/new_test.ex")
    after
      restore_env("PATH", previous_path)
      restore_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS", previous_attempts)
    end
  end

  test "apply codex options can be configured with application config" do
    root = tmp_dir("apply-codex-config")
    bin_dir = tmp_dir("fake-codex-apply-config-bin")
    codex_path = Path.join(bin_dir, "codex")

    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    args="$*"
    root=""
    output=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cd)
          shift
          root="$1"
          ;;
        --output-last-message)
          shift
          output="$1"
          ;;
      esac

      shift
    done

    printf '%s\\n' "$args" >> "$root/codex_args.log"

    if [ -n "$output" ]; then
      printf 'FIX_APPROVED\\n' > "$output"
    fi
    """)

    File.chmod!(codex_path, 0o755)

    previous_path = System.get_env("PATH")
    previous_apply_reasoning = Application.get_env(:review, :codex_apply_reasoning_effort)
    previous_review_reasoning = Application.get_env(:review, :codex_review_reasoning_effort)
    previous_apply_fast = Application.get_env(:review, :codex_apply_fast_mode)
    previous_review_fast = Application.get_env(:review, :codex_review_fast_mode)

    try do
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
      Application.put_env(:review, :codex_apply_reasoning_effort, "high")
      Application.put_env(:review, :codex_review_reasoning_effort, "xhigh")
      Application.put_env(:review, :codex_apply_fast_mode, false)
      Application.put_env(:review, :codex_review_fast_mode, true)

      assert :ok = Review.Apply.Codex.apply_review(root, "review.md", "lib/source.ex", nil)
      assert :approved = Review.Apply.Codex.review_fix(root, "review.md", "lib/source.ex")

      codex_args = File.read!(Path.join(root, "codex_args.log"))
      assert codex_args =~ "model_reasoning_effort=high"
      assert codex_args =~ "model_reasoning_effort=xhigh"
      assert codex_args =~ "--disable fast_mode"
      assert codex_args =~ "--enable fast_mode"
    after
      restore_env("PATH", previous_path)
      restore_app_env(:codex_apply_reasoning_effort, previous_apply_reasoning)
      restore_app_env(:codex_review_reasoning_effort, previous_review_reasoning)
      restore_app_env(:codex_apply_fast_mode, previous_apply_fast)
      restore_app_env(:codex_review_fast_mode, previous_review_fast)
    end
  end

  test "no-commit in-place apply runs on dirty checkout and leaves changes uncommitted" do
    root = tmp_dir("in-place-no-commit")
    bin_dir = tmp_dir("fake-codex-no-commit-bin")
    codex_path = Path.join(bin_dir, "codex")

    run!(root, "git", ["init"])
    run!(root, "git", ["config", "user.email", "test@example.com"])
    run!(root, "git", ["config", "user.name", "Test"])
    write_file!(root, "lib/source.ex", "original\n")
    write_file!(root, "notes.txt", "tracked\n")
    run!(root, "git", ["add", "lib/source.ex", "notes.txt"])
    run!(root, "git", ["commit", "-m", "init"])

    write_file!(root, "notes.txt", "tracked dirty\n")
    write_file!(root, "scratch.log", "untracked dirty\n")

    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    root=""
    output=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cd)
          shift
          root="$1"
          ;;
        --output-last-message)
          shift
          output="$1"
          ;;
      esac

      shift
    done

    prompt=$(cat)

    if [ -z "$output" ]; then
      printf 'changed\\n' > "$root/lib/source.ex"
      printf 'new coverage\\n' > "$root/lib/new_test.ex"
      exit 0
    fi

    if printf '%s' "$prompt" | grep -q "Generate a git commit subject"; then
      printf 'unexpected commit message request\\n' > "$root/commit_message_requested"
      printf 'Unexpected commit\\n' > "$output"
      exit 0
    fi

    if git -C "$root" diff -- lib/new_test.ex | grep -q "new file mode"; then
      printf 'FIX_APPROVED\\n' > "$output"
    else
      {
        printf 'FIX_REJECTED\\n'
        printf -- '- new file was not visible in git diff\\n'
      } > "$output"
    fi
    """)

    File.chmod!(codex_path, 0o755)

    write_file!(
      root,
      "review/lib/source.ex/review.md",
      """
      # Review: lib/source.ex
      Source file: `lib/source.ex`
      Affected files:
      - `lib/source.ex`
      - `lib/new_test.ex`

      ## Overview
      Add split test coverage.
      """
    )

    previous_path = System.get_env("PATH")
    previous_attempts = System.get_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS")

    try do
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
      System.put_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS", "1")

      in_dir(root, fn ->
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert :ok = Review.Apply.main(["--no-commit", "--in-place", "review"])
          end)

        assert output =~ "[ok] uncommitted"
      end)

      assert File.read!(Path.join(root, "notes.txt")) == "tracked dirty\n"
      assert File.read!(Path.join(root, "scratch.log")) == "untracked dirty\n"
      assert File.read!(Path.join(root, "lib/source.ex")) == "changed\n"
      assert File.exists?(Path.join(root, "lib/new_test.ex"))
      refute File.exists?(Path.join(root, "review/lib/source.ex/review.md"))
      refute File.exists?(Path.join(root, "commit_message_requested"))

      assert String.trim(git_output!(root, ["log", "--format=%s", "-1"])) == "init"
      refute git_has_staged_changes?(root)
    after
      restore_env("PATH", previous_path)
      restore_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS", previous_attempts)
    end
  end

  test "no-commit and in-place apply options must be used together" do
    assert_raise Review.Error, ~r/--no-commit requires --in-place/, fn ->
      Review.Apply.main(["--no-commit"])
    end

    assert_raise Review.Error, ~r/--in-place requires --no-commit/, fn ->
      Review.Apply.main(["--in-place"])
    end
  end

  test "profile-root parallel apply runs inside the matching worktree subdirectory" do
    repo_root = tmp_dir("profile-worktree-apply")
    bin_dir = tmp_dir("fake-codex-profile-bin")
    codex_path = Path.join(bin_dir, "codex")

    run!(repo_root, "git", ["init"])
    run!(repo_root, "git", ["config", "user.email", "test@example.com"])
    run!(repo_root, "git", ["config", "user.name", "Test"])
    write_file!(repo_root, "apps/one/lib/a.ex")
    write_file!(repo_root, "apps/one/lib/b.ex")
    run!(repo_root, "git", ["add", "apps/one/lib/a.ex", "apps/one/lib/b.ex"])
    run!(repo_root, "git", ["commit", "-m", "init"])

    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    root=""
    output=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cd)
          shift
          root="$1"
          ;;
        --output-last-message)
          shift
          output="$1"
          ;;
      esac

      shift
    done

    prompt=$(cat)

    if [ -z "$output" ]; then
      if printf '%s' "$prompt" | grep -q "lib/a.ex"; then
        printf 'a review\\n' > "$root/lib/a_review.ex"
      else
        printf 'b review\\n' > "$root/lib/b_review.ex"
      fi

      exit 0
    fi

    if printf '%s' "$prompt" | grep -q "Generate a git commit subject"; then
      printf 'Apply profile review\\n' > "$output"
    else
      printf 'FIX_APPROVED\\n' > "$output"
    fi
    """)

    File.chmod!(codex_path, 0o755)

    write_file!(
      repo_root,
      "apps/one/review/lib/a.ex/review.md",
      """
      # Review: lib/a.ex
      Source file: `lib/a.ex`
      Affected files:
      - `lib/a.ex`
      - `lib/a_review.ex`

      ## Overview
      Add generated review file.
      """
    )

    write_file!(
      repo_root,
      "apps/one/review/lib/b.ex/review.md",
      """
      # Review: lib/b.ex
      Source file: `lib/b.ex`
      Affected files:
      - `lib/b.ex`
      - `lib/b_review.ex`

      ## Overview
      Add generated review file.
      """
    )

    previous_path = System.get_env("PATH")
    previous_profiles = Application.get_env(:review, :profiles)
    previous_attempts = System.get_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS")

    try do
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
      System.put_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS", "1")

      Application.put_env(:review, :profiles,
        one: [
          root: "apps/one",
          review_dir: "review",
          source_dirs: ["lib"],
          source_dirs_mode: :whitelist,
          source_file_extensions: [".ex"]
        ]
      )

      in_dir(repo_root, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Review.Apply.main(["--profile", "one", "review"])
        end)
      end)

      assert File.exists?(Path.join(repo_root, "apps/one/lib/a_review.ex"))
      assert File.exists?(Path.join(repo_root, "apps/one/lib/b_review.ex"))
      refute File.exists?(Path.join(repo_root, "lib/a_review.ex"))
      refute File.exists?(Path.join(repo_root, "lib/b_review.ex"))
    after
      restore_env("PATH", previous_path)
      restore_env("CODEX_FIX_REVIEW_MAX_ATTEMPTS", previous_attempts)
      restore_app_env(:profiles, previous_profiles)
    end
  end

  test "invalid generator input raises a review error instead of halting the VM" do
    assert_raise Review.Error, ~r/Expected a file under/, fn ->
      Review.Generate.main(["/definitely/outside/this/repo.ex"])
    end
  end

  test "generate writes a codex transcript log next to each review file" do
    root = tmp_dir("generate-review-logs")
    bin_dir = tmp_dir("fake-codex-generate-bin")
    codex_path = Path.join(bin_dir, "codex")

    write_file!(root, "lib/a.ex")
    write_file!(root, "lib/b.ex")
    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    output=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output-last-message)
          shift
          output="$1"
          ;;
      esac

      shift
    done

    prompt=$(cat)

    if printf '%s' "$prompt" | grep -q "lib/a.ex"; then
      source="lib/a.ex"
    else
      source="lib/b.ex"
    fi

    printf 'full transcript for %s\\n' "$source"

    {
      printf '# Review: %s\\n' "$source"
      printf 'Source file: `%s`\\n' "$source"
      printf 'Affected files:\\n'
      printf -- '- `%s`\\n' "$source"
      printf '\\n'
      printf '## Overview\\n'
      printf 'Tighten the implementation.\\n'
      printf '## Findings\\n'
      printf 'One concrete finding.\\n'
      printf '## Recommendations\\n'
      printf 'Apply the cleanup.\\n'
      printf '## Verification\\n'
      printf 'Run focused tests.\\n'
    } > "$output"
    """)

    File.chmod!(codex_path, 0o755)

    previous_path = System.get_env("PATH")
    previous_tool_check = System.get_env("REVIEW_TOOL_CHECK")
    previous_concurrency = System.get_env("REVIEW_CONCURRENCY")

    try do
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
      System.put_env("REVIEW_TOOL_CHECK", "0")
      System.put_env("REVIEW_CONCURRENCY", "2")

      in_dir(root, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Review.Generate.main(["lib/a.ex", "lib/b.ex"])
        end)
      end)

      assert File.read!(Path.join(root, "review/lib/a.ex/review.log")) =~
               "full transcript for lib/a.ex"

      assert File.read!(Path.join(root, "review/lib/b.ex/review.log")) =~
               "full transcript for lib/b.ex"
    after
      restore_env("PATH", previous_path)
      restore_env("REVIEW_TOOL_CHECK", previous_tool_check)
      restore_env("REVIEW_CONCURRENCY", previous_concurrency)
    end
  end

  test "generate resume mode resumes the per-review codex session" do
    root = tmp_dir("generate-review-resume")
    bin_dir = tmp_dir("fake-codex-resume-bin")
    codex_path = Path.join(bin_dir, "codex")

    write_file!(root, "lib/a.ex")
    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    args="$*"
    output=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output-last-message)
          shift
          output="$1"
          ;;
      esac

      shift
    done

    printf '%s\\n' "$args" >> codex_args.log

    if printf '%s' "$args" | grep -q "exec resume"; then
      source="lib/a.ex"
      overview="Resumed session review."
    else
      source="lib/a.ex"
      overview="Initial session review."
    fi

    printf '{"type":"thread.started","thread_id":"session-for-lib-a"}\\n'

    {
      printf '# Review: %s\\n' "$source"
      printf 'Source file: `%s`\\n' "$source"
      printf 'Affected files:\\n'
      printf -- '- `%s`\\n' "$source"
      printf '\\n'
      printf '## Overview\\n'
      printf '%s\\n' "$overview"
      printf '## Findings\\n'
      printf 'One concrete finding.\\n'
      printf '## Recommendations\\n'
      printf 'Apply the cleanup.\\n'
      printf '## Verification\\n'
      printf 'Run focused tests.\\n'
    } > "$output"
    """)

    File.chmod!(codex_path, 0o755)

    previous_path = System.get_env("PATH")
    previous_tool_check = System.get_env("REVIEW_TOOL_CHECK")

    try do
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
      System.put_env("REVIEW_TOOL_CHECK", "0")

      in_dir(root, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Review.Generate.main(["lib/a.ex"])
        end)

        assert File.read!("review/lib/a.ex/review.session") == "session-for-lib-a\n"

        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Review.Generate.main(["--resume", "lib/a.ex"])
        end)
      end)

      assert File.read!(Path.join(root, "review/lib/a.ex/review.md")) =~
               "Resumed session review."

      assert File.read!(Path.join(root, "codex_args.log")) =~
               "exec resume --json --output-last-message"

      assert File.read!(Path.join(root, "codex_args.log")) =~ "session-for-lib-a"
    after
      restore_env("PATH", previous_path)
      restore_env("REVIEW_TOOL_CHECK", previous_tool_check)
    end
  end

  test "generate codex options can be configured with application config" do
    root = tmp_dir("generate-codex-config")
    bin_dir = tmp_dir("fake-codex-generate-config-bin")
    codex_path = Path.join(bin_dir, "codex")

    write_file!(root, "lib/a.ex")
    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    args="$*"
    root=""
    output=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cd)
          shift
          root="$1"
          ;;
        --output-last-message)
          shift
          output="$1"
          ;;
      esac

      shift
    done

    printf '%s\\n' "$args" >> "$root/codex_args.log"

    {
      printf '# Review: lib/a.ex\\n'
      printf 'Source file: `lib/a.ex`\\n'
      printf 'Affected files:\\n'
      printf -- '- `lib/a.ex`\\n'
      printf '\\n'
      printf '## Overview\\n'
      printf 'Tighten the implementation.\\n'
      printf '## Findings\\n'
      printf 'One concrete finding.\\n'
      printf '## Recommendations\\n'
      printf 'Apply the cleanup.\\n'
      printf '## Verification\\n'
      printf 'Run focused tests.\\n'
    } > "$output"
    """)

    File.chmod!(codex_path, 0o755)

    previous_path = System.get_env("PATH")
    previous_tool_check = System.get_env("REVIEW_TOOL_CHECK")
    previous_reasoning = Application.get_env(:review, :codex_reasoning_effort)
    previous_fast = Application.get_env(:review, :codex_fast_mode)

    try do
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
      System.put_env("REVIEW_TOOL_CHECK", "0")
      Application.put_env(:review, :codex_reasoning_effort, "medium")
      Application.put_env(:review, :codex_fast_mode, false)

      in_dir(root, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Review.Generate.main(["lib/a.ex"])
        end)
      end)

      codex_args = File.read!(Path.join(root, "codex_args.log"))
      assert codex_args =~ "model_reasoning_effort=medium"
      assert codex_args =~ "--disable fast_mode"
    after
      restore_env("PATH", previous_path)
      restore_env("REVIEW_TOOL_CHECK", previous_tool_check)
      restore_app_env(:codex_reasoning_effort, previous_reasoning)
      restore_app_env(:codex_fast_mode, previous_fast)
    end
  end

  test "invalid blacklist entries raise a review error instead of halting the VM" do
    previous = System.get_env("REVIEW_SOURCE_BLACKLIST")

    try do
      System.put_env("REVIEW_SOURCE_BLACKLIST", "valid,invalid/path")

      assert_raise Review.Error, ~r/Expected blacklist entry/, fn ->
        Review.Common.SourcePolicy.source_blacklist()
      end
    after
      if previous do
        System.put_env("REVIEW_SOURCE_BLACKLIST", previous)
      else
        System.delete_env("REVIEW_SOURCE_BLACKLIST")
      end
    end
  end

  test "configured source dirs limit default source discovery" do
    root = tmp_dir("source-dirs")
    review_dir = Path.join(root, "review")

    write_file!(root, "lib/kept.ex")
    write_file!(root, "assets/kept.ts")
    write_file!(root, "ignored/skipped.ex")
    write_file!(root, "review/lib/kept.ex/review.md")

    previous = Application.get_env(:review, :source_dirs)

    try do
      Application.put_env(:review, :source_dirs, ["lib", "assets"])

      discovered =
        root
        |> Review.Generate.discover_source_files(
          review_dir,
          Review.Common.SourcePolicy.source_policy(),
          Review.Common.Config.source_dirs()
        )
        |> Enum.map(&Path.relative_to(&1, root))
        |> Enum.sort()

      assert discovered == ["assets/kept.ts", "lib/kept.ex"]
    after
      restore_app_env(:source_dirs, previous)
    end
  end

  test "invalid source dirs config raises a review error instead of halting the VM" do
    previous = Application.get_env(:review, :source_dirs)

    try do
      Application.put_env(:review, :source_dirs, [123])

      assert_raise Review.Error, ~r/source_dirs entries/, fn ->
        Review.Common.Config.source_dirs()
      end
    after
      restore_app_env(:source_dirs, previous)
    end
  end

  test "review dir can be configured with application config" do
    root = tmp_dir("review-dir")
    previous = Application.get_env(:review, :review_dir)

    try do
      Application.put_env(:review, :review_dir, "custom_reviews")

      assert Review.Common.Config.review_dir(root) == Path.join(root, "custom_reviews")
    after
      restore_app_env(:review_dir, previous)
    end
  end

  test "source file extensions can be configured with application config" do
    previous = Application.get_env(:review, :source_file_extensions)

    try do
      Application.put_env(:review, :source_file_extensions, [".mdx"])

      assert Review.Common.SourcePolicy.source_file_extension?("docs/page.mdx")
      refute Review.Common.SourcePolicy.source_file_extension?("lib/example.ex")
    after
      restore_app_env(:source_file_extensions, previous)
    end
  end

  test "invalid source file extension config raises a review error" do
    previous = Application.get_env(:review, :source_file_extensions)

    try do
      Application.put_env(:review, :source_file_extensions, ["ex"])

      assert_raise Review.Error, ~r/source_file_extensions entries to start with/, fn ->
        Review.Common.Config.source_file_extensions()
      end
    after
      restore_app_env(:source_file_extensions, previous)
    end
  end

  test "source blacklist can be configured with application config" do
    previous_config = Application.get_env(:review, :source_blacklist)
    previous_env = System.get_env("REVIEW_SOURCE_BLACKLIST")

    try do
      System.delete_env("REVIEW_SOURCE_BLACKLIST")
      Application.put_env(:review, :source_blacklist, ["tmp"])

      assert Review.Common.SourcePolicy.source_blacklist() == ["tmp"]
    after
      restore_app_env(:source_blacklist, previous_config)
      restore_env("REVIEW_SOURCE_BLACKLIST", previous_env)
    end
  end

  test "source blacklist environment variable overrides application config" do
    previous_config = Application.get_env(:review, :source_blacklist)
    previous_env = System.get_env("REVIEW_SOURCE_BLACKLIST")

    try do
      Application.put_env(:review, :source_blacklist, ["tmp"])
      System.put_env("REVIEW_SOURCE_BLACKLIST", "deps")

      assert Review.Common.SourcePolicy.source_blacklist() == ["deps"]
    after
      restore_app_env(:source_blacklist, previous_config)
      restore_env("REVIEW_SOURCE_BLACKLIST", previous_env)
    end
  end

  test "source dirs whitelist mode rejects explicit files outside configured roots" do
    root = tmp_dir("source-dirs-whitelist")
    previous_dirs = Application.get_env(:review, :source_dirs)
    previous_mode = Application.get_env(:review, :source_dirs_mode)

    write_file!(root, "lib/kept.ex")
    write_file!(root, "scripts/skipped.ex")

    try do
      Application.put_env(:review, :source_dirs, ["lib"])
      Application.put_env(:review, :source_dirs_mode, :whitelist)

      in_dir(root, fn ->
        assert_raise Review.Error, ~r/outside configured source_dirs/, fn ->
          Review.Generate.main(["scripts/skipped.ex"])
        end
      end)
    after
      restore_app_env(:source_dirs, previous_dirs)
      restore_app_env(:source_dirs_mode, previous_mode)
    end
  end

  test "selected profile overrides root and source policy" do
    repo_root = tmp_dir("profiles")
    previous_profiles = Application.get_env(:review, :profiles)

    write_file!(repo_root, "apps/one/lib/kept.ex")
    write_file!(repo_root, "apps/one/test/kept_test.exs")
    write_file!(repo_root, "apps/two/lib/skipped.ex")

    try do
      Application.put_env(:review, :profiles,
        one: [
          root: "apps/one",
          review_dir: "reviews",
          source_dirs: ["lib"],
          source_dirs_mode: :whitelist,
          source_file_extensions: [".ex"]
        ]
      )

      in_dir(repo_root, fn ->
        assert Review.Common.Profile.root(repo_root, "one") ==
                 Path.join(repo_root, "apps/one")

        assert_raise Review.Error, ~r/outside configured source_dirs/, fn ->
          Review.Generate.main(["--profile", "one", "test/kept_test.exs"])
        end

        discovered =
          repo_root
          |> Path.join("apps/one")
          |> Review.Generate.discover_source_files(
            Path.join(repo_root, "apps/one/reviews"),
            Review.Common.SourcePolicy.source_policy("one"),
            Review.Common.Config.source_dirs("one")
          )
          |> Enum.map(&Path.relative_to(&1, Path.join(repo_root, "apps/one")))

        assert discovered == ["lib/kept.ex"]
      end)
    after
      restore_app_env(:profiles, previous_profiles)
    end
  end

  test "tooling status reports Elixir xref only for Elixir projects" do
    plain_root = tmp_dir("tooling-plain")
    elixir_root = tmp_dir("tooling-elixir")
    write_file!(elixir_root, "mix.exs")
    write_file!(elixir_root, "lib/example.ex")

    plain_xref =
      plain_root
      |> Review.Tools.Tooling.status()
      |> Enum.find(&(&1.name == "mix xref"))

    elixir_xref =
      elixir_root
      |> Review.Tools.Tooling.status()
      |> Enum.find(&(&1.name == "mix xref"))

    assert plain_xref.status == :not_applicable
    assert match?({:available, "mix"}, elixir_xref.status)
  end

  test "tooling status detects Elixir source without mix project" do
    root = tmp_dir("tooling-elixir-no-mix")
    write_file!(root, "lib/example.ex")

    xref =
      root
      |> Review.Tools.Tooling.status()
      |> Enum.find(&(&1.name == "mix xref"))

    assert xref.status == :not_applicable
    assert xref.detail == "Elixir source detected but no mix.exs found"
  end

  test "tooling prompt guidance exposes repo-specific navigation signals" do
    root = tmp_dir("tooling-prompt")
    write_file!(root, "mix.exs")
    write_file!(root, "lib/example.ex")
    write_file!(root, "scip.json", "{}")

    guidance = Review.Tools.Tooling.prompt_guidance(root)

    assert guidance =~ "Elixir source: yes; mix project: yes"

    assert guidance =~
             "Use elixir-xref-navigation when Elixir source and `mix xref` are available"

    assert guidance =~ "SCIP:"
    assert guidance =~ "configuration"
  end

  test "tooling report can be disabled for generate" do
    previous = System.get_env("REVIEW_TOOL_CHECK")

    try do
      System.put_env("REVIEW_TOOL_CHECK", "0")

      assert capture_io(fn ->
               assert_raise Review.Error, ~r/Expected a file under/, fn ->
                 Review.Generate.main(["/definitely/outside/this/repo.ex"])
               end
             end) == ""
    after
      restore_env("REVIEW_TOOL_CHECK", previous)
    end
  end

  test "tooling install instructions use OS-specific package manager guidance" do
    root = tmp_dir("tooling-install")

    instructions =
      Review.Tools.Tooling.install_instructions(root, %{
        id: "fedora",
        pretty_name: "Fedora Linux 44"
      })

    assert instructions =~ "Fedora Linux 44"
    assert instructions =~ "sudo dnf install -y ripgrep universal-ctags go nodejs npm cargo"
    assert instructions =~ "npm install -g @ast-grep/cli"
    assert instructions =~ "go install github.com/sourcegraph/zoekt/cmd/zoekt@latest"
    assert instructions =~ "mix review.zoekt.index"
    assert instructions =~ "npm install -g @sourcegraph/scip-typescript"
    assert instructions =~ "no repo-local `index.scip`, `.scip/`, or SCIP configuration found"
  end

  test "zoekt index rejects invalid modes before running external tools" do
    assert_raise Review.Error, ~r/Expected --mode to be working-tree or git/, fn ->
      Review.Tools.Zoekt.index(["--mode", "server"], tmp_dir("zoekt-mode"))
    end
  end

  test "mix task converts review errors into Mix errors instead of halting the VM" do
    Mix.Task.reenable("review.generate")

    assert_raise Mix.Error, ~r/Expected a file under/, fn ->
      Mix.Task.run("review.generate", ["/definitely/outside/this/repo.ex"])
    end
  end

  test "review project modules do not call System.halt" do
    halt_references =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          if String.contains?(line, "System.halt") do
            ["#{path}:#{line_number}"]
          else
            []
          end
        end)
      end)

    assert halt_references == []
  end

  defp tmp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "review-test-#{name}-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp write_file!(root, path, content \\ "content") do
    full_path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  defp run!(root, command, args) do
    case System.cmd(command, args, cd: root, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("#{command} #{inspect(args)} exited with #{status}:\n#{output}")
    end
  end

  defp git_output!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{inspect(args)} exited with #{status}:\n#{output}")
    end
  end

  defp git_has_staged_changes?(root) do
    case System.cmd("git", ["diff", "--cached", "--quiet", "--exit-code"], cd: root) do
      {_, 0} -> false
      {_, 1} -> true
      {output, status} -> flunk("git diff --cached exited with #{status}:\n#{output}")
    end
  end

  defp in_dir(path, fun) do
    previous = File.cwd!()

    try do
      File.cd!(path)
      fun.()
    after
      File.cd!(previous)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:review, key)
  defp restore_app_env(key, value), do: Application.put_env(:review, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
