defmodule Mix.Tasks.Review.Tools do
  use Mix.Task

  @shortdoc "Report optional review tooling"

  @moduledoc """
  Reports optional navigation and code-intelligence tools used by review prompts.

      $ mix review.tools
      $ mix review.tools --install

  `--install` detects the current OS before printing install guidance. On Linux
  it reads `/etc/os-release`; on macOS it prints Homebrew-oriented guidance.

  Use `mix help review.tools` to show this documentation.
  """

  @impl Mix.Task
  def run(["--install"]) do
    Review.Tools.Tooling.report_install()
  end

  def run(["-h"]), do: Mix.shell().info(@moduledoc)
  def run(["--help"]), do: Mix.shell().info(@moduledoc)

  def run([]) do
    Review.Tools.Tooling.report()
  end

  def run(args) do
    Mix.raise("Unknown review.tools arguments: #{Enum.join(args, " ")}")
  end
end
