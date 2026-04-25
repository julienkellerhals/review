defmodule Review do
  @moduledoc """
  Mix tasks for generating and applying repository reviews.
  """

  defmodule Error do
    defexception [:message]
  end
end
