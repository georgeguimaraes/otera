defmodule Otera.GroupTuple do
  @moduledoc """
  An item of the result of the `groupby` filter: a Python named tuple `(grouper, list)` with the attributes `grouper` and `list`. It prints and compares like a tuple.
  """

  defstruct [:grouper, :list]

  @doc """
  Returns the group as a plain tuple.
  """
  @spec to_tuple(%__MODULE__{}) :: {term, list}
  def to_tuple(%__MODULE__{grouper: grouper, list: list}), do: {grouper, list}
end
