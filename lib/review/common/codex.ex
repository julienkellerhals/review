defmodule Review.Common.Codex do
  @moduledoc false

  @default_model "gpt-5.5"
  @default_command_max_attempts 3

  def exec(args, prompt, opts \\ []) do
    prompt_path = tmp_path(Keyword.get(opts, :prompt_prefix, "codex-review-prompt"), "md")
    max_attempts = Keyword.get(opts, :max_attempts, command_max_attempts())
    log_path = Keyword.get(opts, :log_path)
    session_path = Keyword.get(opts, :session_path)

    File.write!(prompt_path, prompt)
    reset_log(log_path)

    try do
      result = exec_with_retry(args, prompt_path, max_attempts, 1, log_path)
      maybe_write_session(session_path, result)
      result
    after
      File.rm(prompt_path)
    end
  end

  def runtime_args(args, reasoning_effort) when is_binary(reasoning_effort) do
    runtime_args(args, reasoning_effort: reasoning_effort)
  end

  def runtime_args(args, opts) do
    reasoning_effort = Keyword.fetch!(opts, :reasoning_effort)
    model = Keyword.get(opts, :model, model(Keyword.get(opts, :profile)))
    fast_mode = Keyword.get(opts, :fast_mode)

    fast_mode_args =
      case fast_mode do
        true -> ["--enable", "fast_mode"]
        false -> ["--disable", "fast_mode"]
        nil -> []
      end

    fast_mode_args ++
      [
        "--config",
        "model_reasoning_effort=#{reasoning_effort}",
        "--model",
        model
        | args
      ]
  end

  def model(profile \\ nil) do
    Review.Common.Config.codex_model(profile, @default_model)
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

  defp exec_with_retry(args, prompt_path, max_attempts, attempt, log_path) do
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

    append_log(log_path, attempt, result)

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

          exec_with_retry(args, prompt_path, max_attempts, attempt + 1, log_path)
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

  defp maybe_write_session(nil, _result), do: :ok
  defp maybe_write_session(_session_path, {_output, status}) when status != 0, do: :ok

  defp maybe_write_session(session_path, {output, 0}) do
    case thread_id(output) do
      nil ->
        :ok

      id ->
        File.mkdir_p!(Path.dirname(session_path))
        File.write!(session_path, id <> "\n")
    end
  end

  defp thread_id(output) do
    Regex.run(~r/"type"\s*:\s*"thread\.started".*"thread_id"\s*:\s*"([^"]+)"/, output,
      capture: :all_but_first
    )
    |> case do
      [id] -> id
      _ -> nil
    end
  end

  defp reset_log(nil), do: :ok

  defp reset_log(log_path) do
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "")
  end

  defp append_log(nil, _attempt, _result), do: :ok

  defp append_log(log_path, attempt, {output, status}) do
    File.write!(
      log_path,
      [
        "== Codex attempt #{attempt} exited with #{status} ==\n",
        output,
        maybe_trailing_newline(output)
      ],
      [:append]
    )
  end

  defp maybe_trailing_newline(""), do: ""

  defp maybe_trailing_newline(output) do
    if String.ends_with?(output, "\n"), do: "", else: "\n"
  end
end
