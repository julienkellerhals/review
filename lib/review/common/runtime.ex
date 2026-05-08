defmodule Review.Common.Runtime do
  @moduledoc false

  defstruct [:mode, :profile, :repo_root, :root, :args, :review_dir, :source_policy]

  def from_args!(args, opts \\ []) do
    mode = Keyword.fetch!(opts, :mode)
    repo_root = Keyword.get_lazy(opts, :repo_root, &Review.Common.Repo.root/0)
    {profile, args} = Review.Common.Profile.split_arg(args)
    root = Review.Common.Profile.root(repo_root, profile)

    %__MODULE__{
      mode: mode,
      profile: profile,
      repo_root: repo_root,
      root: root,
      args: args,
      review_dir: Review.Common.Config.review_dir(root, profile),
      source_policy: Review.Common.SourcePolicy.source_policy(profile)
    }
  end
end
