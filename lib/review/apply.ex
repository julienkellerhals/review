defmodule Review.Apply do
  alias Review.Apply.BatchPlanner
  alias Review.Apply.Lifecycle
  alias Review.Apply.Prompts
  alias Review.Apply.ReviewSet
  alias Review.Apply.Terminal
  alias Review.Apply.Transaction
  @default_max_fix_attempts 3
  @default_apply_concurrency 10

  def main(["-h"]), do: usage()
  def main(["--help"]), do: usage()

  def main(args) do
    {mode, runtime_args} = parse_args!(args)
    runtime = Review.Common.Runtime.from_args!(runtime_args, mode: :apply)
    root = runtime.root
    target = ReviewSet.target(root, runtime.args)
    source_policy = runtime.source_policy
    reviews = ReviewSet.files(target)
    Lifecycle.ensure_ready!(root, target, mode: mode)

    apply_reviews!(root, target, source_policy, reviews, mode, runtime.profile)
  end

  defp usage do
    IO.puts("Usage: mix review.apply [review|path/to/review.md]")
    IO.puts("       mix review.apply --profile PROFILE [review|path/to/review.md]")
    IO.puts("       mix review.apply --no-commit --in-place [review|path/to/review.md]")

    IO.puts("Set REVIEW_DIR to change the default review directory.")

    IO.puts(
      "Set REVIEW_SOURCE_BLACKLIST to comma-separated source folder names to exclude. Bare names and **/name/ both match any path segment."
    )

    IO.puts(
      ~s(Configure default source policy with `config :review, source_dirs: ["lib"], source_dirs_mode: :whitelist, source_file_extensions: [".ex"], source_blacklist: ["deps"]`.)
    )

    IO.puts("Set CODEX_MODEL to override the Codex model. Defaults to gpt-5.5.")

    IO.puts(
      "Configure codex_apply_reasoning_effort, codex_review_reasoning_effort, codex_apply_fast_mode, and codex_review_fast_mode in config :review. CODEX_* env vars override config for one run."
    )

    IO.puts("Set CODEX_FIX_REVIEW_MAX_ATTEMPTS to override fix-review retries. Defaults to 3.")

    IO.puts(
      "Set CODEX_COMMAND_MAX_ATTEMPTS to retry retryable Codex command failures. Defaults to 3."
    )

    IO.puts("Set CODEX_APPLY_CONCURRENCY to cap parallel implementation agents. Defaults to 10.")

    IO.puts(
      "Approved reviews are deleted, staged, and committed. Exhausted reviews are annotated and left for a later run."
    )

    IO.puts(
      "Use --no-commit --in-place to apply sequentially into the current checkout and leave changes uncommitted."
    )

    IO.puts("The starting checkout must be clean except for files under the review target.")
  end

  defp parse_args!(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [profile: :string, no_commit: :boolean, in_place: :boolean],
        aliases: [p: :profile]
      )

    if invalid != [] do
      invalid_args =
        invalid
        |> Enum.map_join(" ", fn
          {key, nil} -> key
          {key, value} -> "#{key} #{value}"
        end)

      raise Review.Error, "Unknown review arguments: #{invalid_args}"
    end

    no_commit? = Keyword.get(options, :no_commit, false)
    in_place? = Keyword.get(options, :in_place, false)

    mode =
      cond do
        no_commit? and in_place? ->
          :in_place_no_commit

        no_commit? ->
          raise Review.Error, "--no-commit requires --in-place"

        in_place? ->
          raise Review.Error, "--in-place requires --no-commit"

        true ->
          :commit
      end

    runtime_args =
      case Keyword.fetch(options, :profile) do
        {:ok, profile} -> ["--profile", profile | rest]
        :error -> rest
      end

    {mode, runtime_args}
  end

  defp apply_reviews!(root, target, source_policy, reviews, mode, profile) do
    jobs =
      reviews
      |> Enum.flat_map(fn review_path ->
        case ReviewSet.build_job(root, target, source_policy, review_path) do
          {:ok, job} ->
            [job]

          {:stale, source_file, message} ->
            relative_review = Path.relative_to(review_path, root)

            Transaction.skip_stale(root, review_path, relative_review, source_file, message,
              mode: mode
            )

            []

          {:skip_invalid_affected_file, message} ->
            Terminal.warning(message)
            []
        end
      end)

    if jobs == [] do
      Terminal.info("No applicable reviews left after skipping review files")
      :ok
    else
      apply_review_jobs!(root, target, source_policy, jobs, mode, profile)
    end
  end

  defp apply_review_jobs!(root, target, source_policy, jobs, mode, profile) do
    concurrency = apply_concurrency(mode)
    batches = BatchPlanner.plan(jobs, concurrency)

    Terminal.plan(length(jobs), length(batches), concurrency)

    started_branch = Lifecycle.current_branch!(root)
    total_batches = length(batches)

    batches
    |> Enum.with_index(1)
    |> Enum.each(fn {batch, index} ->
      Terminal.batch_start(index, total_batches, batch, concurrency)

      Lifecycle.run_batch!(
        root,
        target,
        batch,
        started_branch: started_branch,
        apply_review: fn review_root, review_target, review_path ->
          Transaction.apply(
            review_root,
            review_target,
            source_policy,
            review_path,
            max_attempts: max_fix_attempts(),
            mode: mode,
            profile: profile
          )
        end,
        skip_stale: fn review_root, job ->
          Transaction.skip_stale(
            review_root,
            job.review_path,
            job.relative_review,
            job.source_file,
            ReviewSet.stale_source_message(job.relative_review, job.source_file),
            mode: mode
          )
        end
      )

      Terminal.batch_done(total_batches - index)
    end)
  end

  def plan_review_batches(jobs, concurrency) do
    BatchPlanner.plan(jobs, concurrency)
  end

  defp apply_concurrency(:in_place_no_commit), do: 1

  defp apply_concurrency(:commit) do
    Review.Common.Env.positive_integer("CODEX_APPLY_CONCURRENCY", @default_apply_concurrency)
  end

  defp max_fix_attempts do
    Review.Common.Env.positive_integer("CODEX_FIX_REVIEW_MAX_ATTEMPTS", @default_max_fix_attempts)
  end

  def apply_prompt(relative_review, source_file, nil) do
    Prompts.apply_prompt(relative_review, source_file, nil)
  end

  def apply_prompt(relative_review, source_file, previous_rejection) do
    Prompts.apply_prompt(relative_review, source_file, previous_rejection)
  end
end
