defmodule ReviewTest do
  use ExUnit.Case, async: false

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
        Review.SourcePolicy.source_blacklist()
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
          Review.SourcePolicy.source_blacklist(),
          Review.Config.source_dirs()
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
        Review.Config.source_dirs()
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

      assert Review.Config.review_dir(root) == Path.join(root, "custom_reviews")
    after
      restore_app_env(:review_dir, previous)
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
end
