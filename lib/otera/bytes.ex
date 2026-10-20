defmodule Otera.Bytes do
  @moduledoc """
  A Python `bytes` value, which `str.encode()` gives. It prints like Python, such as `b'caf\\xc3\\xa9'`, has a length in bytes, iterates as integers, and `decode()` gives the string back.
  """

  defstruct data: ""

  @type t :: %__MODULE__{data: binary}

  @codecs ["utf-8", "utf8", "utf_8", "ascii", "latin-1", "latin1", "iso-8859-1"]

  @doc """
  Encodes `string` like `str.encode(encoding, errors)`, for the codecs UTF-8, ASCII and Latin-1 with strict errors.
  """
  @spec encode(String.t(), String.t()) :: t
  def encode(string, encoding) do
    case codec(encoding) do
      :utf8 ->
        %__MODULE__{data: string}

      limit ->
        case Enum.find_index(String.to_charlist(string), &(&1 > limit)) do
          nil -> %__MODULE__{data: :unicode.characters_to_binary(string, :utf8, :latin1)}
          index -> encode_error(string, index, limit)
        end
    end
  end

  @doc """
  Decodes `bytes` like `bytes.decode(encoding)`.
  """
  @spec decode(t, String.t()) :: String.t()
  def decode(%__MODULE__{data: data}, encoding) do
    case codec(encoding) do
      :utf8 ->
        if String.valid?(data),
          do: data,
          else:
            raise(Otera.Error,
              kind: :unicode_decode_error,
              message: "'utf-8' codec can't decode the bytes"
            )

      127 ->
        if data =~ ~r/\A[\x00-\x7F]*\z/,
          do: data,
          else:
            raise(Otera.Error,
              kind: :unicode_decode_error,
              message: "'ascii' codec can't decode the bytes"
            )

      255 ->
        :unicode.characters_to_binary(data, :latin1, :utf8)
    end
  end

  @doc """
  Returns the Python `repr()` of `bytes`.
  """
  @spec repr(t) :: String.t()
  def repr(%__MODULE__{data: data}) do
    quote = if String.contains?(data, "'") and not String.contains?(data, "\""), do: ?", else: ?'

    escaped =
      for <<byte <- data>>, into: "" do
        case byte do
          byte when byte in [quote, ?\\] ->
            <<?\\, byte>>

          ?\t ->
            "\\t"

          ?\n ->
            "\\n"

          ?\r ->
            "\\r"

          byte when byte in 0x20..0x7E ->
            <<byte>>

          byte ->
            "\\x" <> String.downcase(String.pad_leading(Integer.to_string(byte, 16), 2, "0"))
        end
      end

    "b" <> <<quote, escaped::binary, quote>>
  end

  defp codec(encoding) do
    case String.downcase(encoding) do
      name when name in ["utf-8", "utf8", "utf_8"] -> :utf8
      "ascii" -> 127
      name when name in @codecs -> 255
      _ -> raise Otera.Error, kind: :lookup_error, message: "unknown encoding: #{encoding}"
    end
  end

  defp encode_error(string, index, limit) do
    char = string |> String.to_charlist() |> Enum.at(index)
    name = if limit == 127, do: "ascii", else: "latin-1"

    raise Otera.Error,
      kind: :unicode_encode_error,
      message:
        "'#{name}' codec can't encode character '#{unicode_escape(char)}' in position #{index}: ordinal not in range(#{limit + 1})"
  end

  defp unicode_escape(char) when char <= 0xFF, do: "\\x" <> hex(char, 2)
  defp unicode_escape(char) when char <= 0xFFFF, do: "\\u" <> hex(char, 4)
  defp unicode_escape(char), do: "\\U" <> hex(char, 8)

  defp hex(char, size),
    do: char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")
end
