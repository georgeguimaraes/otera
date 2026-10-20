defmodule Otera.Method do
  @moduledoc """
  A Python method bound to a value, such as `message.content.strip` or `loop.cycle`. `Otera.Methods` runs it when the template calls it.
  """

  defstruct [:receiver, :name]
end
