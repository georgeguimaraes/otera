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

  As in Python, a repeated key keeps its first position and its last value, and the keys `1`, `1.0` and `true` are the same key.
  """
  @spec new([{term, term}]) :: t
  def new(pairs) do
    {reversed, _seen} =
      Enum.reduce(pairs, {[], MapSet.new()}, fn {key, value}, {acc, seen} ->
        normal = normalize(key)

        if MapSet.member?(seen, normal),
          do: {replace(acc, normal, value), seen},
          else: {[{key, value} | acc], MapSet.put(seen, normal)}
      end)

    %__MODULE__{pairs: Enum.reverse(reversed)}
  end

  @doc """
  Returns `{:ok, value}` for `key`, or `:error`.
  """
  @impl Access
  @spec fetch(t, term) :: {:ok, term} | :error
  def fetch(%__MODULE__{pairs: pairs}, key) do
    normal = normalize(key)

    case Enum.find(pairs, fn {k, _} -> normalize(k) === normal end) do
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
      {:ok, value} ->
        {value,
         %__MODULE__{pairs: Enum.reject(pairs, &(normalize(elem(&1, 0)) === normalize(key)))}}

      :error ->
        {nil, dict}
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
    normal = normalize(key)

    if Enum.any?(pairs, &(normalize(elem(&1, 0)) === normal)),
      do: replace(pairs, normal, value),
      else: pairs ++ [{key, value}]
  end

  defp replace(pairs, normal, value),
    do: Enum.map(pairs, fn {k, v} -> if normalize(k) === normal, do: {k, value}, else: {k, v} end)

  # Python hashes equal numbers alike, so True, 1 and 1.0 are one key.
  defp normalize(%Otera.Markup{text: text}), do: text
  defp normalize(true), do: 1
  defp normalize(false), do: 0
  defp normalize(key) when is_float(key) and key == trunc(key), do: trunc(key)
  defp normalize(key), do: key
end

defimpl Enumerable, for: Otera.Dict do
  def count(%{pairs: pairs}), do: {:ok, length(pairs)}
  def member?(%{pairs: pairs}, pair), do: {:ok, pair in pairs}
  def slice(%{pairs: pairs}), do: {:ok, length(pairs), &Enum.slice(pairs, &1, &2)}
  def reduce(%{pairs: pairs}, acc, fun), do: Enumerable.List.reduce(pairs, acc, fun)
end
