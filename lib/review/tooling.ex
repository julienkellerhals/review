defmodule Review.Tooling do
  @moduledoc false

  @skip_values ["0", "false", "no", "off"]

  def report(root \\ repo_root()) do
    root
    |> status()
    |> format()
    |> IO.puts()
  end

  def report_install(root \\ repo_root()) do
    root
    |> install_instructions(detect_os())
    |> IO.puts()
  end

  def maybe_report(root) do
    unless skip_tool_check?() do
      report(root)
    end
  end

  def status(root \\ repo_root()) do
    root = Path.expand(root)

    [
      %{
        name: "ripgrep",
        status: executable_status(["rg"]),
        detail: "baseline fast text search"
      },
      %{
        name: "ast-grep",
        status: executable_status(["sg", "ast-grep"]),
        detail: "syntax-aware structural search"
      },
      zoekt_status(),
      elixir_xref_status(root),
      scip_status(root)
    ]
  end

  def prompt_guidance(root \\ repo_root()) do
    root = Path.expand(root)

    [
      "Detected optional tooling for this repository:",
      "- Elixir source: #{yes_no?(elixir_source?(root))}; mix project: #{yes_no?(mix_project?(root))}; mix executable: #{yes_no?(System.find_executable("mix"))}. Use elixir-xref-navigation when Elixir source and `mix xref` are available.",
      "- SCIP: #{scip_prompt_status(root)}. Use scip-code-intelligence only when a repo-local index or query path exists.",
      "- Zoekt: #{availability_text(zoekt_status().status)}. Use zoekt-code-search only when indexed search is available or the repo has an existing Zoekt setup.",
      "- ast-grep: #{availability_text(executable_status(["sg", "ast-grep"]))}. Use ast-grep-code-search for structural matches when available."
    ]
    |> Enum.join("\n")
  end

  def format(statuses) do
    lines =
      Enum.map(statuses, fn status ->
        "- #{status.name}: #{format_status(status.status)} (#{status.detail})"
      end)

    Enum.join(["Optional review tooling:" | lines], "\n")
  end

  def install_instructions(root \\ repo_root(), os_info \\ detect_os()) do
    root = Path.expand(root)
    os_label = os_info[:pretty_name] || os_info[:id] || :os.type() |> elem(0) |> Atom.to_string()

    [
      "Optional review tooling install notes for #{os_label}:",
      "",
      os_package_instructions(os_info),
      "",
      "Language/runtime-distributed tools:",
      "- ast-grep: `npm install -g @ast-grep/cli`",
      "- Zoekt: `go install github.com/sourcegraph/zoekt/cmd/zoekt@latest`",
      "- Zoekt directory indexer: `go install github.com/sourcegraph/zoekt/cmd/zoekt-index@latest`",
      "- Zoekt git indexer: `go install github.com/sourcegraph/zoekt/cmd/zoekt-git-index@latest`",
      "- After installing Zoekt, build a working-tree index with `mix review.zoekt.index`.",
      "- TypeScript/JavaScript SCIP indexer: `npm install -g @sourcegraph/scip-typescript`",
      "- Python SCIP indexer: `npm install -g @sourcegraph/scip-python`",
      "",
      scip_note(root),
      "",
      "Elixir projects:",
      "- `mix xref` is included with Mix. Install project dependencies before relying on xref output.",
      "",
      "Check again with `mix review.tools`."
    ]
    |> Enum.join("\n")
  end

  def detect_os do
    case :os.type() do
      {:unix, :darwin} ->
        %{id: "macos", pretty_name: "macOS"}

      {:unix, _name} ->
        read_os_release()

      _ ->
        %{id: "unknown", pretty_name: "unknown OS"}
    end
  end

  defp skip_tool_check? do
    "REVIEW_TOOL_CHECK"
    |> System.get_env()
    |> case do
      nil -> false
      value -> String.downcase(String.trim(value)) in @skip_values
    end
  end

  defp executable_status(names) do
    case Enum.find(names, &System.find_executable/1) do
      nil -> :missing
      name -> {:available, name}
    end
  end

  defp zoekt_status do
    search = executable_status(["zoekt"])
    index = executable_status(["zoekt-index", "zoekt-git-index"])

    case {search, index} do
      {{:available, search}, {:available, index}} ->
        %{
          name: "Zoekt",
          status: {:available, "#{search}, #{index}"},
          detail: "indexed source search"
        }

      _ ->
        %{
          name: "Zoekt",
          status: :missing,
          detail: "indexed source search; needs zoekt plus zoekt-index or zoekt-git-index"
        }
    end
  end

  defp elixir_xref_status(root) do
    cond do
      not elixir_source?(root) ->
        %{name: "mix xref", status: :not_applicable, detail: "Elixir dependency graph"}

      not mix_project?(root) ->
        %{
          name: "mix xref",
          status: :not_applicable,
          detail: "Elixir source detected but no mix.exs found"
        }

      System.find_executable("mix") ->
        %{name: "mix xref", status: {:available, "mix"}, detail: "Elixir dependency graph"}

      true ->
        %{
          name: "mix xref",
          status: :missing,
          detail: "Elixir project detected but mix is missing"
        }
    end
  end

  defp scip_status(root) do
    index? = scip_index?(root)
    config? = scip_config?(root)
    tooling = scip_tooling()

    cond do
      index? and tooling != [] ->
        %{
          name: "SCIP",
          status: {:available, Enum.join(tooling, ", ")},
          detail: "precise code intelligence with repo-local index"
        }

      index? ->
        %{
          name: "SCIP",
          status: :partial,
          detail: "repo-local index found; install scip/src tooling to query or upload it"
        }

      config? and tooling != [] ->
        %{
          name: "SCIP",
          status: :partial,
          detail: "SCIP config and tooling found, but no repo-local index found"
        }

      config? ->
        %{
          name: "SCIP",
          status: :partial,
          detail: "SCIP config found, but no repo-local index or tooling found"
        }

      tooling != [] ->
        %{
          name: "SCIP",
          status: :partial,
          detail: "tooling found (#{Enum.join(tooling, ", ")}), but no repo-local index found"
        }

      true ->
        %{
          name: "SCIP",
          status: :missing,
          detail: "precise code intelligence; optional unless a repo-local index is available"
        }
    end
  end

  defp os_package_instructions(%{id: id}) when id in ["fedora", "rhel", "centos"] do
    """
    OS packages:
    - `sudo dnf install -y ripgrep universal-ctags go nodejs npm cargo`
    - `cargo` is only needed if you prefer installing ast-grep with `cargo install ast-grep`.
    """
    |> String.trim()
  end

  defp os_package_instructions(%{id: id}) when id in ["debian", "ubuntu"] do
    """
    OS packages:
    - `sudo apt update`
    - `sudo apt install -y ripgrep universal-ctags golang-go nodejs npm cargo`
    - `cargo` is only needed if you prefer installing ast-grep with `cargo install ast-grep`.
    """
    |> String.trim()
  end

  defp os_package_instructions(%{id: "arch"}) do
    """
    OS packages:
    - `sudo pacman -S ripgrep universal-ctags go nodejs npm rust`
    - Rust is only needed if you prefer installing ast-grep with `cargo install ast-grep`.
    """
    |> String.trim()
  end

  defp os_package_instructions(%{id: "macos"}) do
    """
    OS packages:
    - `brew install ripgrep universal-ctags go node rust`
    - Rust is only needed if you prefer installing ast-grep with `cargo install ast-grep`.
    """
    |> String.trim()
  end

  defp os_package_instructions(_os_info) do
    """
    OS packages:
    - Install `ripgrep`, `universal-ctags`, Go, Node.js/npm, and optionally Rust/Cargo with your system package manager.
    """
    |> String.trim()
  end

  defp scip_note(root) do
    cond do
      scip_index?(root) ->
        "SCIP: repo-local index detected. Install `scip`, `src`, or the relevant indexer/query tooling if you need to inspect it locally."

      scip_config?(root) ->
        "SCIP: repo-local SCIP configuration detected, but no `index.scip` or `.scip/` was found. Generate an index only when this repo already expects SCIP-based navigation."

      true ->
        "SCIP: no repo-local `index.scip`, `.scip/`, or SCIP configuration found. Do not create one for routine reviews unless this repo already uses SCIP or the user asks for setup."
    end
  end

  defp scip_prompt_status(root) do
    cond do
      scip_index?(root) and scip_tooling() != [] ->
        "index and tooling available"

      scip_index?(root) ->
        "index available, query tooling missing"

      scip_config?(root) and scip_tooling() != [] ->
        "configuration and tooling available, index missing"

      scip_config?(root) ->
        "configuration available, index and query tooling missing"

      scip_tooling() != [] ->
        "tooling available, repo-local index/config missing"

      true ->
        "no repo-local index/config detected"
    end
  end

  defp scip_index?(root) do
    File.regular?(Path.join(root, "index.scip")) or File.dir?(Path.join(root, ".scip"))
  end

  defp scip_config?(root) do
    Enum.any?(
      [
        "scip.json",
        ".scip.json",
        "scip.yml",
        "scip.yaml",
        ".sourcegraph/config.json"
      ],
      &(File.regular?(Path.join(root, &1)) or File.dir?(Path.join(root, &1)))
    )
  end

  defp scip_tooling do
    ["scip", "scip-typescript", "scip-python", "src"]
    |> Enum.filter(&System.find_executable/1)
  end

  defp elixir_source?(root) do
    root
    |> source_file_exists?([".ex", ".exs", ".heex"])
  end

  defp mix_project?(root), do: File.regular?(Path.join(root, "mix.exs"))

  defp source_file_exists?(root, extensions) do
    root = Path.expand(root)

    root
    |> File.ls()
    |> case do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          path = Path.join(root, entry)

          cond do
            blacklisted_tooling_path?(entry) ->
              false

            File.dir?(path) ->
              source_file_exists?(path, extensions)

            File.regular?(path) ->
              Path.extname(path) in extensions

            true ->
              false
          end
        end)

      {:error, _reason} ->
        false
    end
  end

  defp blacklisted_tooling_path?(entry) do
    entry in [
      ".git",
      ".elixir_ls",
      "_build",
      "deps",
      "node_modules",
      "vendor",
      "review"
    ]
  end

  defp availability_text({:available, command}), do: "available via #{command}"
  defp availability_text(:missing), do: "missing"

  defp yes_no?(value) do
    if value, do: "yes", else: "no"
  end

  defp read_os_release do
    "/etc/os-release"
    |> File.read()
    |> case do
      {:ok, content} ->
        fields =
          content
          |> String.split("\n")
          |> Enum.flat_map(&parse_os_release_line/1)
          |> Map.new()

        %{
          id: Map.get(fields, "ID", "unknown"),
          pretty_name: Map.get(fields, "PRETTY_NAME", Map.get(fields, "ID", "unknown Linux"))
        }

      {:error, _reason} ->
        %{id: "unknown", pretty_name: "unknown Linux"}
    end
  end

  defp parse_os_release_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] when key != "" ->
        [{key, value |> String.trim() |> String.trim(~s("))}]

      _ ->
        []
    end
  end

  defp format_status({:available, command}), do: "available via #{command}"
  defp format_status(:partial), do: "partial"
  defp format_status(:not_applicable), do: "not applicable"
  defp format_status(:missing), do: "missing"

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> root |> String.trim() |> Path.expand()
      _ -> File.cwd!()
    end
  end
end
