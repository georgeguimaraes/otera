defmodule Otera.State do
  @moduledoc """
  The mutable state of a render, for the Python objects that templates change: `namespace()` objects and the last value of `loop.changed()`.

  Values are immutable in Elixir, so `run/1` keeps this state in the process dictionary for the length of a render, and restores the previous state after it, so that a render inside a custom filter does not see the state of the outer render.
  """

  @doc """
  Runs `fun` with an empty state.
  """
  @spec run((-> result)) :: result when result: term
  def run(fun) do
    previous = Process.put(__MODULE__, %{})

    try do
      fun.()
    after
      if previous, do: Process.put(__MODULE__, previous), else: Process.delete(__MODULE__)
    end
  end

  @doc """
  Returns the value for `key`, or `default`.
  """
  @spec get(term, term) :: term
  def get(key, default \\ nil), do: Map.get(Process.get(__MODULE__), key, default)

  @doc """
  Sets the value for `key`.
  """
  @spec put(term, term) :: :ok
  def put(key, value) do
    Process.put(__MODULE__, Map.put(Process.get(__MODULE__), key, value))
    :ok
  end
end
