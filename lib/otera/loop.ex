defmodule Otera.Loop do
  @moduledoc """
  The `loop` variable inside a `{% for %}` block, like the `LoopContext` of Jinja2.

  It has `index`, `index0`, `revindex`, `revindex0`, `first`, `last`, `length`, `depth`, `depth0`, `previtem` and `nextitem`, the methods `cycle` and `changed`, and for a recursive loop it can be called with the items of the next level.

  Each iteration gets a new `Loop` with the same `ref`. `changed` keeps its last value for the `ref` in `Otera.State`, and so does the look ahead of `last`, `nextitem` and `length`, which takes items from an iterator.
  """

  alias Otera.{Method, State, Undefined, Value}

  defstruct [:ref, :items, :index0, :depth0, :recurse]

  @doc """
  Returns the attribute `name` of `loop`.
  """
  @spec get(%__MODULE__{}, String.t()) :: term
  def get(loop, "index0"), do: loop.index0
  def get(loop, "index"), do: loop.index0 + 1
  def get(loop, "first"), do: loop.index0 == 0

  def get(loop, name) when name in ["length", "revindex", "revindex0"] do
    peek(loop, :all)
    length = tuple_size(loop.items)

    case name do
      "length" -> length
      "revindex" -> length - loop.index0
      "revindex0" -> length - loop.index0 - 1
    end
  end

  def get(loop, "last") do
    peek(loop, loop.index0)
    loop.index0 == tuple_size(loop.items) - 1
  end

  def get(loop, "depth0"), do: loop.depth0
  def get(loop, "depth"), do: loop.depth0 + 1

  def get(%{index0: 0}, "previtem"), do: %Undefined{hint: "there is no previous item"}
  def get(loop, "previtem"), do: elem(loop.items, loop.index0 - 1)

  def get(loop, "nextitem") do
    peek(loop, loop.index0)

    if loop.index0 + 1 < tuple_size(loop.items),
      do: elem(loop.items, loop.index0 + 1),
      else: %Undefined{hint: "there is no next item"}
  end

  def get(loop, name) when name in ["cycle", "changed"], do: %Method{receiver: loop, name: name}
  def get(loop, name), do: %Undefined{obj: loop, name: name}

  @doc """
  Returns true when `values` differ from the values of the previous call in this loop, like `loop.changed(*values)`.
  """
  @spec changed?(%__MODULE__{}, list) :: boolean
  def changed?(loop, values) do
    values = List.to_tuple(values)
    key = {__MODULE__, loop.ref}

    if Value.equal?(State.get(key, :missing), values) do
      false
    else
      State.put(key, values)
      true
    end
  end

  # The LoopContext of Jinja2 takes the next item of the iterator to answer `last` and `nextitem`,
  # and all the items for `length`. A loop that breaks gives the other items back to an iterator.
  defp peek(loop, peek) do
    key = {__MODULE__, :peek, loop.ref}
    if State.get(key) != :all, do: State.put(key, peek)
  end

  @doc """
  Returns how many items after `index0` the loop took from its iterator to look ahead: `:all`, 1 or 0.
  """
  @spec peeked(reference, non_neg_integer) :: :all | 0 | 1
  def peeked(loop_ref, index0) do
    case State.get({__MODULE__, :peek, loop_ref}) do
      :all -> :all
      ^index0 -> 1
      _ -> 0
    end
  end

  @doc """
  Returns the items after the current one as `{item, loop}` pairs, which Python gives when a template iterates over the loop.
  """
  @spec remaining(%__MODULE__{}) :: [{term, %__MODULE__{}}]
  def remaining(loop) do
    loop.items |> Tuple.to_list() |> Enum.drop(loop.index0 + 1) |> Enum.map(&{&1, loop})
  end
end
