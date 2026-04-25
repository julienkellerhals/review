defmodule Review.MixProject do
  use Mix.Project

  def project do
    [
      app: :review,
      version: "0.1.0",
      elixir: "~> 1.15",
      description: description(),
      package: package(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    []
  end

  defp description do
    "Mix tasks for generating, applying, and cleaning up Codex review workflows."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{}
    ]
  end
end
