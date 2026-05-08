defmodule Mix.Tasks.Review.Zoekt.Index do
  use Mix.Task

  @shortdoc "Build a local Zoekt index for the current checkout"

  @moduledoc """
  Builds a local Zoekt index for the current checkout.

      $ mix review.zoekt.index
      $ mix review.zoekt.index --index ~/.zoekt
      $ mix review.zoekt.index --mode git

  The default mode uses `zoekt-index`, which indexes the current working tree
  and is usually the right choice for review workflows. `--mode git` uses
  `zoekt-git-index`, which indexes git data and may not reflect uncommitted
  changes.

  This task does not clone repositories and does not install Zoekt. Run
  `mix review.tools --install` for OS-aware setup notes.
  """

  @impl Mix.Task
  def run(args) do
    Review.Zoekt.index(args)
  rescue
    exception in [Review.Error] ->
      Mix.raise(Exception.message(exception))
  end
end
