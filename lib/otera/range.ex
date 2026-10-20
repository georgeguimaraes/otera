defmodule Otera.Range do
  @moduledoc """
  The Python `range` object that `range()` gives in a template.

  It prints as `range(0, 3)`, has a length, takes an index or a slice, supports `in`, and gives its items when a template iterates over it. A slice of a range is a range.
  """

  alias Otera.Value

  defstruct [:start, :stop, :step]

  @type t :: %__MODULE__{start: integer, stop: integer, step: integer}

  @doc """
  Returns the number of items of `range`.
  """
  @spec size(t) :: non_neg_integer
  def size(%__MODULE__{start: start, stop: stop, step: step}) do
    if step > 0,
      do: max(0, div(stop - start + step - 1, step)),
      else: max(0, div(start - stop - step - 1, -step))
  end

  @doc """
  Returns the items of `range` as a list.
  """
  @spec to_list(t) :: [integer]
  def to_list(range), do: Enum.map(0..(size(range) - 1)//1, &(range.start + &1 * range.step))

  @doc """
  Returns the Python `repr()` of `range`, such as `range(0, 3)` or `range(0, 10, 2)`.
  """
  @spec repr(t) :: String.t()
  def repr(%__MODULE__{start: start, stop: stop, step: 1}), do: "range(#{start}, #{stop})"

  def repr(%__MODULE__{start: start, stop: stop, step: step}),
    do: "range(#{start}, #{stop}, #{step})"

  @doc """
  Returns `{:ok, item}` for the item at `index`, which can be negative, or `:error`.
  """
  @spec fetch(t, integer) :: {:ok, integer} | :error
  def fetch(range, index) do
    index = if index < 0, do: size(range) + index, else: index

    if index >= 0 and index < size(range),
      do: {:ok, range.start + index * range.step},
      else: :error
  end

  @doc """
  Returns true if `item` is an item of `range`. An integer is an item when the arithmetic of the range gives it, and another value when it equals an item.
  """
  @spec member?(t, term) :: boolean
  def member?(range, item) when is_integer(item) or is_boolean(item) do
    item = if is_boolean(item), do: if(item, do: 1, else: 0), else: item
    offset = item - range.start

    rem(offset, range.step) == 0 and
      ((range.step > 0 and item >= range.start and item < range.stop) or
         (range.step < 0 and item <= range.start and item > range.stop))
  end

  def member?(range, item), do: Enum.any?(to_list(range), &Value.equal?(&1, item))

  @doc """
  Returns `range[start:stop:step]` as a range, where `start` and `stop` are the bounds that `slice.indices` gives for the length of `range`.
  """
  @spec slice(t, integer, integer, integer) :: t
  def slice(range, start, stop, step),
    do: %__MODULE__{
      start: range.start + start * range.step,
      stop: range.start + stop * range.step,
      step: range.step * step
    }
end
