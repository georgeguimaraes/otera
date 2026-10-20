defmodule Otera.Iterable do
  @moduledoc """
  A Python iterable that is not a list or a tuple, with the behavior of its Python type.

  `type` is the name of the Python type:

    * `"dict_keys"`, `"dict_values"` and `"dict_items"`, from the methods `keys()`, `values()` and `items()` of a dict. A view prints as `dict_keys([...])`, has a length, and is false when it is empty. A view keeps its `items`.
    * `"generator"`, from the filters `map`, `select`, `reject`, `selectattr`, `rejectattr`, `unique`, `items`, `batch` and `slice`, and the reverse iterators of the `reverse` filter, such as `"list_reverseiterator"`. An iterator is always true and has no length, so `x|select("odd")|length` raises like in Python.

  An iterator makes a single pass, like in Python: its remaining items live in `Otera.State` under `ref`, and each operation takes the items that Python takes. A second loop over the same generator gets no items, `first` takes one item, and `in` takes the items up to the first match.
  """

  alias Otera.State

  defstruct [:type, :items, :ref]

  @type t :: %__MODULE__{type: String.t(), items: list | nil, ref: reference | nil}

  @views ["dict_keys", "dict_values", "dict_items"]

  @doc """
  Makes an iterable of the Python type `type` with `items`.
  """
  @spec new(String.t(), list) :: t
  def new(type, items) when type in @views, do: %__MODULE__{type: type, items: items}

  def new(type, items) do
    ref = make_ref()
    State.put(ref, items)
    %__MODULE__{type: type, ref: ref}
  end

  @doc """
  Returns true for the dict views, which have a length.
  """
  @spec view?(t) :: boolean
  def view?(%__MODULE__{type: type}), do: type in @views

  @doc """
  Returns the items of `iterable`. An iterator gives its remaining items and is empty after it.
  """
  @spec take_all(t) :: list
  def take_all(%__MODULE__{ref: nil, items: items}), do: items

  def take_all(%__MODULE__{ref: ref}) do
    items = State.get(ref)
    State.put(ref, [])
    items
  end

  @doc """
  Takes the items up to and including the first item for which `fun` returns true, and returns true if there was such an item, like the Python iteration of `in`.
  """
  @spec take_until(t, (term -> boolean)) :: boolean
  def take_until(%__MODULE__{ref: nil, items: items}, fun), do: Enum.any?(items, fun)

  def take_until(%__MODULE__{ref: ref}, fun) do
    {_skipped, rest} = Enum.split_while(State.get(ref), &(not fun.(&1)))
    State.put(ref, Enum.drop(rest, 1))
    rest != []
  end

  @doc """
  Takes the next item of `iterable`: `{:ok, item}`, or `:error` when there is none.
  """
  @spec next(t) :: {:ok, term} | :error
  def next(%__MODULE__{ref: nil, items: [item | _]}), do: {:ok, item}
  def next(%__MODULE__{ref: nil}), do: :error

  def next(%__MODULE__{ref: ref}) do
    case State.get(ref) do
      [item | rest] ->
        State.put(ref, rest)
        {:ok, item}

      [] ->
        :error
    end
  end

  @doc """
  Gives `items` back to an iterator, for the items that a loop did not reach.
  """
  @spec give_back(t, list) :: :ok
  def give_back(%__MODULE__{ref: nil}, _items), do: :ok
  def give_back(%__MODULE__{ref: ref}, items), do: State.put(ref, items ++ State.get(ref))
end
