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

  test "invalid generator input raises a review error instead of halting the VM" do
    assert_raise Review.Error, ~r/Expected a file under/, fn ->
      Review.Generate.main(["/definitely/outside/this/repo.ex"])
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
          Review.Common.SourcePolicy.source_blacklist(),
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
