defmodule Review.Common.Codex do
  @moduledoc false

  @default_model "gpt-5.5"
  @default_command_max_attempts 3

  def exec(args, prompt, opts \\ []) do
    prompt_path = tmp_path(Keyword.get(opts, :prompt_prefix, "codex-review-prompt"), "md")
    max_attempts = Keyword.get(opts, :max_attempts, command_max_attempts())

    File.write!(prompt_path, prompt)

    try do
      exec_with_retry(args, prompt_path, max_attempts, 1)
    after
      File.rm(prompt_path)
    end
  end

  def runtime_args(args, reasoning_effort) do
    [
      "--config",
      "model_reasoning_effort=#{reasoning_effort}",
      "--model",
      model()
      | args
    ]
  end

  def model do
    Review.Common.Env.string("CODEX_MODEL", @default_model)
  end

  def tmp_markdown_path(prefix) do
    tmp_path(prefix, "md")
  end

  def tmp_path(prefix, extension) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.#{extension}")
  end

  def read_and_remove(path) do
    content =
      case File.read(path) do
        {:ok, content} -> content
        {:error, _reason} -> ""
      end

    File.rm(path)
    content
  end

  defp command_max_attempts do
    Review.Common.Env.positive_integer(
      "CODEX_COMMAND_MAX_ATTEMPTS",
      @default_command_max_attempts
    )
  end

  defp exec_with_retry(args, prompt_path, max_attempts, attempt) do
    result =
      System.cmd(
        "sh",
        [
          "-c",
          "prompt_path=$1; shift; \"$@\" < \"$prompt_path\"",
          "codex-stdin",
          prompt_path,
          "codex" | args
        ],
        stderr_to_stdout: true
      )

    case result do
      {_output, 0} ->
        result

      {output, _status} when attempt < max_attempts ->
        if retryable_failure?(output) do
          maybe_report_failed_log(result)

          IO.puts(
            :stderr,
            "Retrying Codex command after retryable failure (attempt #{attempt + 1}/#{max_attempts})"
          )

          exec_with_retry(args, prompt_path, max_attempts, attempt + 1)
        else
          maybe_report_failed_log(result)
          result
        end

      {_output, _status} ->
        maybe_report_failed_log(result)
        result
    end
  end

  defp maybe_report_failed_log({_output, 0}), do: :ok

  defp maybe_report_failed_log({output, _status}) do
    IO.puts(:stderr, "Codex log:")
    IO.puts(:stderr, output)
  end

  defp retryable_failure?(log) do
    normalized = String.downcase(log)

    Enum.any?(
      [
        "context_length_exceeded",
        "compact_remote",
        "error running remote compact task",
        "input exceeds the context window",
        "remote compaction failed"
      ],
      &String.contains?(normalized, &1)
    )
  end
end
