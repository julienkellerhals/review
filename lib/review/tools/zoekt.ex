defmodule Review.Tools.Zoekt do
  @moduledoc false

  def index(args \\ [], root \\ Review.Common.Repo.root()) do
    {options, rest} = parse_args(args)

    if rest != [] do
      raise Review.Error, "Unexpected review.zoekt.index arguments: #{Enum.join(rest, " ")}"
    end

    root = Path.expand(root)
    index_dir = Path.expand(options[:index] || default_index_dir())
    indexer = zoekt_indexer!(options[:mode])
    File.mkdir_p!(index_dir)

    IO.puts("Indexing #{root} into #{index_dir} with #{Path.basename(indexer)}")

    case System.cmd(indexer, ["-index", index_dir, root], stderr_to_stdout: true) do
      {output, 0} ->
        output = String.trim(output)

        if output != "" do
          IO.puts(output)
        end

        IO.puts("Zoekt index ready. Search with: zoekt -index #{shell_quote(index_dir)} 'query'")
        :ok

      {output, status} ->
        raise Review.Error,
              "zoekt indexer exited with #{status}:\n#{String.trim(output)}"
    end
  end

  def default_index_dir do
    Path.join(System.user_home!(), ".zoekt")
  end

  defp parse_args(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          index: :string,
          mode: :string
        ]
      )

    if invalid != [] do
      invalid_args =
        invalid
        |> Enum.map_join(" ", fn
          {key, nil} -> key
          {key, value} -> "#{key} #{value}"
        end)

      raise Review.Error, "Unknown review.zoekt.index arguments: #{invalid_args}"
    end

    mode =
      case options[:mode] do
        nil ->
          :working_tree

        "working-tree" ->
          :working_tree

        "git" ->
          :git

        mode ->
          raise Review.Error, "Expected --mode to be working-tree or git, got: #{inspect(mode)}"
      end

    {[index: options[:index], mode: mode], rest}
  end

  defp zoekt_indexer!(:working_tree) do
    System.find_executable("zoekt-index") ||
      raise Review.Error,
            "Expected zoekt-index on PATH. Run `mix review.tools --install` for setup notes."
  end

  defp zoekt_indexer!(:git) do
    System.find_executable("zoekt-git-index") ||
      raise Review.Error,
            "Expected zoekt-git-index on PATH. Run `mix review.tools --install` for setup notes."
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
