defmodule Otera.Unicode do
  @moduledoc """
  The character properties of Python `str` methods, such as `isprintable()`, `isdigit()` and the cased letters of `title()`.

  The properties come from `priv/unicode_properties.json`, which `scripts/generate_unicode_properties.py` writes from the predicates of the pinned Python, so Otera uses the Unicode version of the Python reference and not the one of Erlang/OTP. Each property is a sorted tuple of code point ranges, and a lookup is a binary search.
  """

  @external_resource Path.expand("../../priv/unicode_properties.json", __DIR__)
  @data @external_resource |> File.read!() |> JSON.decode!()

  for name <- ~w(printable alpha decimal digit numeric space lower upper title) do
    ranges =
      @data[name]
      |> Enum.chunk_every(2)
      |> Enum.map(&List.to_tuple/1)
      |> List.to_tuple()

    defp ranges(unquote(String.to_atom(name))), do: unquote(Macro.escape(ranges))
  end

  @doc """
  Returns true if Python `repr()` prints `char` as it is, like `str.isprintable()`.
  """
  @spec printable?(char) :: boolean
  def printable?(char), do: in?(:printable, char)

  @doc """
  Returns true for a cased character: a lowercase, uppercase or titlecase letter.
  """
  @spec cased?(char) :: boolean
  def cased?(char), do: lowercase?(char) or uppercase?(char) or in?(:title, char)

  @doc """
  Returns true for a character with the Lowercase property, like `str.islower()` of one character.
  """
  @spec lowercase?(char) :: boolean
  def lowercase?(char), do: in?(:lower, char)

  @doc """
  Returns true for a character with the Uppercase property, like `str.isupper()` of one character.
  """
  @spec uppercase?(char) :: boolean
  def uppercase?(char), do: in?(:upper, char)

  @doc """
  Returns true for a letter, like `str.isalpha()`.
  """
  @spec alpha?(char) :: boolean
  def alpha?(char), do: in?(:alpha, char)

  @doc """
  Returns true for a decimal digit, like `str.isdecimal()`.
  """
  @spec decimal?(char) :: boolean
  def decimal?(char), do: in?(:decimal, char)

  @doc """
  Returns true for a digit, like `str.isdigit()`.
  """
  @spec digit?(char) :: boolean
  def digit?(char), do: in?(:digit, char)

  @doc """
  Returns true for a numeric character, like `str.isnumeric()`.
  """
  @spec numeric?(char) :: boolean
  def numeric?(char), do: in?(:numeric, char)

  @doc """
  Returns true for whitespace, like `str.isspace()`.
  """
  @spec space?(char) :: boolean
  def space?(char), do: in?(:space, char)

  defp in?(property, char) do
    ranges = ranges(property)
    search(ranges, char, 0, tuple_size(ranges) - 1)
  end

  defp search(_ranges, _char, low, high) when low > high, do: false

  defp search(ranges, char, low, high) do
    middle = div(low + high, 2)

    case elem(ranges, middle) do
      {first, _last} when char < first -> search(ranges, char, low, middle - 1)
      {_first, last} when char > last -> search(ranges, char, middle + 1, high)
      _inside -> true
    end
  end
end
