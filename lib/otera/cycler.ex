defmodule Otera.Cycler do
  @moduledoc """
  The `cycler(*items)` object of Jinja2. `next()` gives the current item and moves to the next one, `reset()` goes back to the first item, and `current` is the item that `next()` gives next. The position lives in `Otera.State`.
  """

  alias Otera.{Method, State, Undefined}

  defstruct [:ref, :items]

  @doc """
  Makes a cycler over `items`.
  """
  @spec new(list) :: %__MODULE__{}
  def new([]),
    do: raise(Otera.Error, kind: :runtime_error, message: "at least one item has to be provided")

  def new(items) do
    cycler = %__MODULE__{ref: make_ref(), items: List.to_tuple(items)}
    State.put(cycler.ref, 0)
    cycler
  end

  @doc """
  Returns the attribute `name` of `cycler`.
  """
  @spec get(%__MODULE__{}, String.t()) :: term
  def get(cycler, "current"), do: elem(cycler.items, State.get(cycler.ref))
  def get(cycler, "items"), do: cycler.items
  def get(cycler, name) when name in ["next", "reset"], do: %Method{receiver: cycler, name: name}
  def get(cycler, name), do: %Undefined{obj: cycler, name: name}

  @doc """
  Calls the method `next` or `reset`.
  """
  @spec call(%__MODULE__{}, String.t()) :: term
  def call(cycler, "next") do
    current = get(cycler, "current")
    State.put(cycler.ref, rem(State.get(cycler.ref) + 1, tuple_size(cycler.items)))
    current
  end

  def call(cycler, "reset") do
    State.put(cycler.ref, 0)
    nil
  end
end
