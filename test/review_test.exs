defmodule ReviewTest do
  use ExUnit.Case, async: true

  test "apply prompts expose shared workflow guidance" do
    prompt = Review.Apply.apply_prompt("architecture_reviews/foo/review.md", "lib/foo.ex", nil)

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
end
