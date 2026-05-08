defmodule Review.Common.Env do
  @moduledoc false

  def string(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  def positive_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 ->
            integer

          _ ->
            raise Review.Error,
                  "Expected #{name} to be a positive integer, got: #{inspect(value)}"
        end
    end
  end
end
