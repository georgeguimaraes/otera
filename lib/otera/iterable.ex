defmodule Otera.Iterable do
  @moduledoc """
  A Python iterable that is not a list or a tuple, with the behavior of its Python type.

  `type` is the name of the Python type:

    * `"dict_keys"`, `"dict_values"` and `"dict_items"`, from the methods `keys()`, `values()` and `items()` of a dict. A view prints as `dict_keys([...])`, has a length, and is false when it is empty.
    * `"generator"`, from the filters `map`, `select`, `reject`, `selectattr`, `rejectattr`, `unique`, `items`, `batch` and `slice`, and the reverse iterators of the `reverse` filter, such as `"list_reverseiterator"`. An iterator is always true and has no length, so `x|select("odd")|length` raises like in Python.

  A template iterates over these values like a list. Otera does not model the single pass of a Python iterator, so a template can iterate over a generator twice.
  """

  defstruct [:type, :items]

  @type t :: %__MODULE__{type: String.t(), items: list}

  @doc """
  Returns true for the dict views, which have a length.
  """
  @spec view?(t) :: boolean
  def view?(%__MODULE__{type: type}), do: type in ["dict_keys", "dict_values", "dict_items"]
end
