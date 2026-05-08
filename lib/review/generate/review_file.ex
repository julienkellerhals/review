defmodule Review.Generate.ReviewFile do
  @moduledoc false

  alias Review.Generate.Codex

  def review(root, review_dir, source) do
    relative_source = Path.relative_to(source, root)
    review_path = Path.join([review_dir, relative_source, "review.md"])

    if File.regular?(review_path) do
      IO.puts("Skipping #{relative_source}: review already exists")
      :ok
    else
      Codex.run_review(root, review_path, relative_source)
    end
  end
end
