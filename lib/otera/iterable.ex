defmodule Otera.Iterable do
  @moduledoc """
  A Python iterable that is not a list or a tuple, with the behavior of its Python type.

  `type` is the name of the Python type:

    * `"dict_keys"`, `"dict_values"` and `"dict_items"`, from the methods `keys()`, `values()` and `items()` of a dict. A view prints as `dict_keys([...])`, has a length, and is false when it is empty. A view keeps its `items`.
    * `"generator"`, from the filters `map`, `select`, `reject`, `selectattr`, `rejectattr`, `unique`, `items`, `batch` and `slice`, and the reverse iterators of the `reverse` filter, such as `"list_reverseiterator"`. An iterator is always true and has no length, so `x|select("odd")|length` raises like in Python.

  An iterator is lazy and makes a single pass, like in Python. Its state lives in `Otera.State` under `ref`: a step function and its accumulator. Each `next/1` runs the step once, so a generator does its work, and raises its errors, only when a template takes its items. Two loops over the same generator share its items, `first` takes one item, and `in` takes the items up to the first match.
  """

  alias Otera.{State, Value}

  defstruct [:type, :items, :ref]

  @type t :: %__MODULE__{type: String.t(), items: list | nil, ref: reference | nil}

  @typedoc """
  A step gets the accumulator and gives the next item and the new accumulator, or `:done`.
  """
  @type step :: (term -> {:ok, term, term} | :done)

  @views ["dict_keys", "dict_values", "dict_items"]

  @doc """
  Makes an iterable of the Python type `type` with `items`: a view, or an iterator over the items.
  """
  @spec new(String.t(), list) :: t
  def new(type, items) when type in @views, do: %__MODULE__{type: type, items: items}
  def new(type, items), do: lazy(type, items, &list_step/1)

  @doc """
  Makes an iterator of the Python type `type` that runs `step`, starting with the accumulator `acc`.
  """
  @spec lazy(String.t(), term, step) :: t
  def lazy(type, acc, step) do
    ref = make_ref()
    State.put(ref, {step, acc})
    %__MODULE__{type: type, ref: ref}
  end

  @doc """
  Returns an iterator over `value`, like Python `iter()`: an iterator gives itself, and another value gives a new iterator, which takes the items of `value` at its first step.
  """
  @spec iter(term) :: t
  def iter(%__MODULE__{ref: ref} = iterator) when ref != nil, do: iterator
  def iter(value), do: lazy("iterator", value, &first_step/1)

  defp first_step(value), do: list_step(Value.to_list(value))

  @doc """
  Returns a source of items for `pull/1`: an iterator gives itself, and another value gives its items when `pull/1` first takes one, like the `for` loop of a Python generator.
  """
  @spec source(term) :: t | {:items, term} | {:list, list}
  def source(%__MODULE__{ref: ref} = iterator) when ref != nil, do: iterator
  def source(value), do: {:items, value}

  @doc """
  Takes the next item of a source of `source/1`: `{:ok, item, source}`, or `:done`.
  """
  @spec pull(t | {:items, term} | {:list, list}) :: {:ok, term, term} | :done
  def pull({:items, value}), do: pull({:list, Value.to_list(value)})
  def pull({:list, [item | rest]}), do: {:ok, item, {:list, rest}}
  def pull({:list, []}), do: :done

  def pull(iterator) do
    case next(iterator) do
      {:ok, item} -> {:ok, item, iterator}
      :error -> :done
    end
  end

  defp list_step([item | rest]), do: {:ok, item, rest}
  defp list_step([]), do: :done

  @doc """
  Returns true for the dict views, which have a length.
  """
  @spec view?(t) :: boolean
  def view?(%__MODULE__{type: type}), do: type in @views

  @doc """
  Takes the next item of `iterable`: `{:ok, item}`, or `:error` when there is none.
  """
  @spec next(t) :: {:ok, term} | :error
  def next(%__MODULE__{ref: nil, items: [item | _]}), do: {:ok, item}
  def next(%__MODULE__{ref: nil}), do: :error

  def next(%__MODULE__{ref: ref}) do
    {step, acc} = State.get(ref)

    case step.(acc) do
      {:ok, item, acc} ->
        State.put(ref, {step, acc})
        {:ok, item}

      :done ->
        State.put(ref, {&list_step/1, []})
        :error
    end
  end

  @doc """
  Returns the items of `iterable`. An iterator gives its remaining items and is empty after it.
  """
  @spec take_all(t) :: list
  def take_all(%__MODULE__{ref: nil, items: items}), do: items
  def take_all(iterator), do: take_all(iterator, [])

  defp take_all(iterator, acc) do
    case next(iterator) do
      {:ok, item} -> take_all(iterator, [item | acc])
      :error -> Enum.reverse(acc)
    end
  end

  @doc """
  Takes the items up to and including the first item for which `fun` returns true, and returns true if there was such an item, like the Python iteration of `in`.
  """
  @spec take_until(t, (term -> boolean)) :: boolean
  def take_until(%__MODULE__{ref: nil, items: items}, fun), do: Enum.any?(items, fun)

  def take_until(iterator, fun) do
    case next(iterator) do
      {:ok, item} -> fun.(item) or take_until(iterator, fun)
      :error -> false
    end
  end
end
