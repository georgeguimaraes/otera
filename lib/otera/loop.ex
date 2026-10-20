defmodule Otera.Loop do
  @moduledoc """
  The `loop` variable inside a `{% for %}` block, like the `LoopContext` of Jinja2.

  It has `index`, `index0`, `revindex`, `revindex0`, `first`, `last`, `length`, `depth`, `depth0`, `previtem` and `nextitem`, the methods `cycle` and `changed`, and for a recursive loop it can be called with the items of the next level.

  A loop takes its items one at a time from an `Otera.Iterable`. Each iteration gets a new `Loop` with the same `ref`, and `Otera.State` keeps the iterator and the items that the loop took to look ahead under that `ref`. Like Jinja2, `last` and `nextitem` take the next item, and `length` and `revindex` take all the items, so a loop over a generator shares the items of that generator with the other code that reads it. `changed` keeps its last value in `Otera.State` too.
  """

  alias Otera.{Iterable, Method, State, Undefined, Value}

  defstruct [:ref, :index0, :depth0, :recurse, previous: :none]

  @doc """
  Starts a loop over the iterator `source` and returns its reference.
  """
  @spec start(Iterable.t()) :: reference
  def start(source) do
    ref = make_ref()
    State.put({__MODULE__, ref}, {source, []})
    ref
  end

  @doc """
  Takes the next item of the loop `ref`: `{:ok, item}`, or `:error` at the end.
  """
  @spec next(reference) :: {:ok, term} | :error
  def next(ref) do
    case State.get({__MODULE__, ref}) do
      {source, [item | ahead]} ->
        State.put({__MODULE__, ref}, {source, ahead})
        {:ok, item}

      {source, []} ->
        Iterable.next(source)
    end
  end

  @doc """
  Returns the attribute `name` of `loop`.
  """
  @spec get(%__MODULE__{}, String.t()) :: term
  def get(loop, "index0"), do: loop.index0
  def get(loop, "index"), do: loop.index0 + 1
  def get(loop, "first"), do: loop.index0 == 0
  def get(loop, "length"), do: loop.index0 + 1 + length(take_all(loop))
  def get(loop, "revindex"), do: length(take_all(loop)) + 1
  def get(loop, "revindex0"), do: length(take_all(loop))
  def get(loop, "last"), do: peek(loop) == :error
  def get(loop, "depth0"), do: loop.depth0
  def get(loop, "depth"), do: loop.depth0 + 1

  def get(%{previous: :none}, "previtem"), do: %Undefined{hint: "there is no previous item"}
  def get(%{previous: {:ok, item}}, "previtem"), do: item

  def get(loop, "nextitem") do
    case peek(loop) do
      {:ok, item} -> item
      :error -> %Undefined{hint: "there is no next item"}
    end
  end

  def get(loop, name) when name in ["cycle", "changed"], do: %Method{receiver: loop, name: name}
  def get(loop, name), do: %Undefined{obj: loop, name: name}

  # Takes the next item to look ahead, which the next iteration gets.
  defp peek(loop) do
    case State.get({__MODULE__, loop.ref}) do
      {_source, [item | _]} ->
        {:ok, item}

      {source, []} ->
        with {:ok, item} <- Iterable.next(source) do
          State.put({__MODULE__, loop.ref}, {source, [item]})
          {:ok, item}
        end
    end
  end

  # Takes all the items after the current one to look ahead, for the length of the loop.
  defp take_all(loop) do
    {source, ahead} = State.get({__MODULE__, loop.ref})
    ahead = ahead ++ Iterable.take_all(source)
    State.put({__MODULE__, loop.ref}, {source, ahead})
    ahead
  end

  @doc """
  Returns true when `values` differ from the values of the previous call in this loop, like `loop.changed(*values)`.
  """
  @spec changed?(%__MODULE__{}, list) :: boolean
  def changed?(loop, values) do
    values = List.to_tuple(values)
    key = {__MODULE__, :changed, loop.ref}

    if Value.equal?(State.get(key, :missing), values) do
      false
    else
      State.put(key, values)
      true
    end
  end

  @doc """
  Takes the items after the current one as `{item, loop}` pairs, which Python gives when a template iterates over the loop. The loop has no items after it.
  """
  @spec remaining(%__MODULE__{}) :: [{term, %__MODULE__{}}]
  def remaining(loop) do
    items = take_all(loop)
    State.put({__MODULE__, loop.ref}, {elem(State.get({__MODULE__, loop.ref}), 0), []})

    items
    |> Enum.with_index(loop.index0 + 1)
    |> Enum.map(fn {item, index0} -> {item, %{loop | index0: index0}} end)
  end
end
