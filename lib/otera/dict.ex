defmodule Otera.Dict do
  @moduledoc """
  A dictionary that keeps the insertion order of its keys, like a Python `dict`.

  Templates see every map as a dict. The key order matters when a template iterates over a dict or prints it with `tojson`. Elixir maps do not keep the insertion order, so Otera gives the keys of a plain map in sorted order. To give the keys in a specific order, pass an `Otera.Dict`:

      Otera.Dict.new([{"role", "user"}, {"content", "Hello"}])

  `Otera.JSON.decode!/1` decodes JSON objects into `Otera.Dict` structs, with the key order of the JSON text, like `json.loads` in Python.

  A dict works with the `Access` syntax, `dict["role"]`, and enumerates its `{key, value}` pairs in order.
  """

  @behaviour Access

  defstruct pairs: []

  @type t :: %__MODULE__{pairs: [{term, term}]}

  @doc """
  Makes a dict from a list of `{key, value}` pairs.

  As in Python, a repeated key keeps the position of its first occurrence and the value of its last.
  """
  @spec new([{term, term}]) :: t
  def new(pairs) do
    {reversed, _seen} =
      Enum.reduce(pairs, {[], MapSet.new()}, fn {key, value}, {acc, seen} ->
        if MapSet.member?(seen, key),
          do: {List.keyreplace(acc, key, 0, {key, value}), seen},
          else: {[{key, value} | acc], MapSet.put(seen, key)}
      end)

    %__MODULE__{pairs: Enum.reverse(reversed)}
  end

  @doc """
  Returns `{:ok, value}` for `key`, or `:error`.
  """
  @impl Access
  @spec fetch(t, term) :: {:ok, term} | :error
  def fetch(%__MODULE__{pairs: pairs}, key) do
    case List.keyfind(pairs, key, 0) do
      {_, value} -> {:ok, value}
      nil -> :error
    end
  end

  @doc """
  Sets `key` to `value`. A new key goes to the end.
  """
  @spec put(t, term, term) :: t
  def put(%__MODULE__{pairs: pairs}, key, value), do: %__MODULE__{pairs: store(pairs, key, value)}

  @impl Access
  def get_and_update(dict, key, fun) do
    current =
      case fetch(dict, key) do
        {:ok, value} -> value
        :error -> nil
      end

    case fun.(current) do
      {get, update} -> {get, put(dict, key, update)}
      :pop -> pop(dict, key)
    end
  end

  @impl Access
  def pop(%__MODULE__{pairs: pairs} = dict, key) do
    case fetch(dict, key) do
      {:ok, value} -> {value, %__MODULE__{pairs: List.keydelete(pairs, key, 0)}}
      :error -> {nil, dict}
    end
  end

  @doc """
  Returns the keys in order.
  """
  @spec keys(t) :: [term]
  def keys(%__MODULE__{pairs: pairs}), do: Enum.map(pairs, &elem(&1, 0))

  @doc """
  Returns the values in order.
  """
  @spec values(t) :: [term]
  def values(%__MODULE__{pairs: pairs}), do: Enum.map(pairs, &elem(&1, 1))

  defp store(pairs, key, value) do
    if List.keymember?(pairs, key, 0),
      do: List.keyreplace(pairs, key, 0, {key, value}),
      else: pairs ++ [{key, value}]
  end
end

defimpl Enumerable, for: Otera.Dict do
  def count(%{pairs: pairs}), do: {:ok, length(pairs)}
  def member?(%{pairs: pairs}, pair), do: {:ok, pair in pairs}
  def slice(%{pairs: pairs}), do: {:ok, length(pairs), &Enum.slice(pairs, &1, &2)}
  def reduce(%{pairs: pairs}, acc, fun), do: Enumerable.List.reduce(pairs, acc, fun)
end
