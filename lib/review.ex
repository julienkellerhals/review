defmodule Review do
  @moduledoc """
  Mix tasks for generating and applying repository architecture reviews.
  """

  defmodule Error do
    defexception [:message]
  end
end
