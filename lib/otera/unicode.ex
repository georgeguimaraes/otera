defmodule Otera.Unicode do
  @moduledoc """
  The character properties of Python `str` methods, such as `isprintable()`, `isdigit()` and the cased letters of `title()`.

  The general categories come from the Unicode data of Erlang. Python adds some properties that are not categories: the `Other_Lowercase` and `Other_Uppercase` letters are cased, `isdigit()` also accepts digits like `²`, and `isnumeric()` also accepts numerals like `一`.
  """

  # Lowercase and uppercase letters outside the categories Ll and Lu, from PropList.txt.
  @other_lowercase [
    0xAA..0xAA,
    0xBA..0xBA,
    0x2B0..0x2B8,
    0x2C0..0x2C1,
    0x2E0..0x2E4,
    0x345..0x345,
    0x37A..0x37A,
    0x10FC..0x10FC,
    0x1D2C..0x1D6A,
    0x1D78..0x1D78,
    0x1D9B..0x1DBF,
    0x2071..0x2071,
    0x207F..0x207F,
    0x2090..0x209C,
    0x2170..0x217F,
    0x24D0..0x24E9,
    0x2C7C..0x2C7D,
    0xA69C..0xA69D,
    0xA770..0xA770,
    0xA7F8..0xA7F9,
    0xAB5C..0xAB5F,
    0x10780..0x10780,
    0x10783..0x10785,
    0x10787..0x107B0,
    0x107B2..0x107BA
  ]

  @other_uppercase [
    0x2160..0x216F,
    0x24B6..0x24CF,
    0x1F130..0x1F149,
    0x1F150..0x1F169,
    0x1F170..0x1F189
  ]

  # Characters with Numeric_Type=Digit, which isdigit() accepts besides the decimal digits.
  @digits [
    0xB2..0xB3,
    0xB9..0xB9,
    0x1369..0x1371,
    0x19DA..0x19DA,
    0x2070..0x2070,
    0x2074..0x2079,
    0x2080..0x2089,
    0x2460..0x2468,
    0x2474..0x247C,
    0x2488..0x2490,
    0x24EA..0x24EA,
    0x24F5..0x24FD,
    0x24FF..0x24FF,
    0x2776..0x277E,
    0x2780..0x2788,
    0x278A..0x2792,
    0x10A40..0x10A43,
    0x10E60..0x10E68,
    0x11052..0x1105A,
    0x1F100..0x1F10A
  ]

  # CJK ideographs with a numeric value, which isnumeric() accepts.
  @ideograph_numerals String.to_charlist("〇一二三四五六七八九十百千万萬億亿兆零壹贰貳弐叁參参肆伍陆陸柒捌玖拾佰仟廿卅卌两兩弌弍弎")

  @doc """
  Returns true if Python `repr()` prints `char` as it is. Python escapes the categories Cc, Cf, Cs, Co, Cn, Zl, Zp, and Zs other than the space.
  """
  @spec printable?(char) :: boolean
  def printable?(?\s), do: true

  def printable?(char) do
    case :unicode_util.category(char) do
      {:other, _} -> false
      {:separator, _} -> false
      _ -> true
    end
  end

  @doc """
  Returns true for a cased character: a lowercase, uppercase or titlecase letter.
  """
  @spec cased?(char) :: boolean
  def cased?(char),
    do:
      lowercase?(char) or uppercase?(char) or
        :unicode_util.category(char) == {:letter, :titlecase}

  @doc """
  Returns true for a character with the Lowercase property.
  """
  @spec lowercase?(char) :: boolean
  def lowercase?(char),
    do:
      :unicode_util.category(char) == {:letter, :lowercase} or in_ranges?(char, @other_lowercase)

  @doc """
  Returns true for a character with the Uppercase property.
  """
  @spec uppercase?(char) :: boolean
  def uppercase?(char),
    do:
      :unicode_util.category(char) == {:letter, :uppercase} or in_ranges?(char, @other_uppercase)

  @doc """
  Returns true for a letter, like `str.isalpha()`.
  """
  @spec alpha?(char) :: boolean
  def alpha?(char), do: match?({:letter, _}, :unicode_util.category(char))

  @doc """
  Returns true for a decimal digit, like `str.isdecimal()`.
  """
  @spec decimal?(char) :: boolean
  def decimal?(char), do: :unicode_util.category(char) == {:number, :decimal}

  @doc """
  Returns true for a digit, like `str.isdigit()`.
  """
  @spec digit?(char) :: boolean
  def digit?(char), do: decimal?(char) or in_ranges?(char, @digits)

  @doc """
  Returns true for a numeric character, like `str.isnumeric()`.
  """
  @spec numeric?(char) :: boolean
  def numeric?(char),
    do: match?({:number, _}, :unicode_util.category(char)) or char in @ideograph_numerals

  defp in_ranges?(char, ranges), do: Enum.any?(ranges, &(char in &1))
end
