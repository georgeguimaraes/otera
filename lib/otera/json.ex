defmodule Otera.JSON do
  @moduledoc """
  JSON with the rules of Python `json`: `dumps/2` for the `tojson` filter, and `decode!/1` to keep the key order of objects.

  `dumps/2` gives the same text as Python `json.dumps`, with its options `ensure_ascii`, `indent`, `separators` and `sort_keys`. Floats use the Python `repr()`, so `1.0` stays `1.0`.
  """

  alias Otera.{Dict, Value}

  @doc """
  Decodes JSON text into template values. Objects become `Otera.Dict` structs with the key order of the text, like `json.loads` in Python.

  Use it to give a template the tool definitions or messages of a JSON request, so that `tojson` prints their keys in the same order as transformers.

      iex> Otera.JSON.decode!(~s({"b": 1, "a": 2}))
      %Otera.Dict{pairs: [{"b", 1}, {"a", 2}]}
  """
  @spec decode!(String.t()) :: term
  def decode!(json) do
    decoders = [
      object_start: fn _acc -> [] end,
      object_push: fn key, value, acc -> [{key, value} | acc] end,
      object_finish: fn acc, old_acc -> {Dict.new(Enum.reverse(acc)), old_acc} end
    ]

    case JSON.decode(json, nil, decoders) do
      {value, nil, ""} -> value
      {:error, _reason} -> JSON.decode!(json)
    end
  end

  @doc """
  Encodes `value` like Python `json.dumps`.

  Options: `:ensure_ascii` (default `true`), `:indent` (an integer or a string), `:separators` (a `{item, key}` tuple) and `:sort_keys` (default `false`).
  """
  @spec dumps(term, keyword) :: String.t()
  def dumps(value, opts \\ []) do
    {item_separator, key_separator} =
      separators(Keyword.get(opts, :separators), Keyword.get(opts, :indent))

    ascii = Keyword.get(opts, :ensure_ascii, true)

    # Like Python, a string encodes before the indent is checked.
    if is_binary(value) do
      value |> encode_string(ascii) |> IO.iodata_to_binary()
    else
      options = %{
        ascii: ascii,
        indent: indent(Keyword.get(opts, :indent)),
        item: item_separator,
        key: key_separator,
        sort: Keyword.get(opts, :sort_keys, false)
      }

      value |> encode(options, 0) |> IO.iodata_to_binary()
    end
  end

  defp indent(nil), do: nil
  defp indent(indent) when is_integer(indent), do: String.duplicate(" ", max(indent, 0))
  defp indent(indent) when is_boolean(indent), do: if(indent, do: " ", else: "")
  defp indent(indent) when is_binary(indent), do: indent

  defp indent(indent),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "can't multiply sequence by non-int of type '#{Value.type_name(indent)}'"
      )

  defp separators(nil, nil), do: {", ", ": "}
  defp separators(nil, _indent), do: {",", ": "}

  # Python unpacks the separators from any iterable of two items.
  defp separators(separators, _indent) do
    case Value.to_list(separators) do
      [item, key] ->
        {item, key}

      items when length(items) < 2 ->
        raise Otera.Error,
          kind: :value_error,
          message: "not enough values to unpack (expected 2, got #{length(items)})"

      _items ->
        raise Otera.Error, kind: :value_error, message: "too many values to unpack (expected 2)"
    end
  end

  defp encode(nil, _options, _level), do: "null"
  defp encode(true, _options, _level), do: "true"
  defp encode(false, _options, _level), do: "false"
  defp encode(value, _options, _level) when is_integer(value), do: Integer.to_string(value)
  defp encode(value, _options, _level) when is_float(value), do: Value.format_float(value)

  defp encode(value, options, _level) when is_binary(value),
    do: encode_string(value, options.ascii)

  defp encode(%Otera.GroupTuple{} = group, options, level),
    do: encode(Value.to_list(group), options, level)

  defp encode(value, options, level) when is_tuple(value),
    do: encode(Tuple.to_list(value), options, level)

  defp encode([], _options, _level), do: "[]"

  defp encode(list, options, level) when is_list(list) do
    {open, separator, close} = layout(options, level)
    items = Enum.map(list, &encode(&1, options, level + 1))
    ["[", open, Enum.intersperse(items, separator), close, "]"]
  end

  defp encode(%Dict{pairs: []}, _options, _level), do: "{}"

  defp encode(%Dict{pairs: pairs}, options, level) do
    {open, separator, close} = layout(options, level)
    pairs = if options.sort, do: sort_pairs(pairs), else: pairs

    items =
      Enum.map(pairs, fn {key, value} ->
        [
          encode_string(key_string(key), options.ascii),
          options.key,
          encode(value, options, level + 1)
        ]
      end)

    ["{", open, Enum.intersperse(items, separator), close, "}"]
  end

  defp encode(value, _options, _level) do
    raise Otera.Error,
      kind: :type_error,
      message: "Object of type #{Value.type_name(value)} is not JSON serializable"
  end

  defp layout(%{indent: nil, item: item}, _level), do: {"", item, ""}

  defp layout(%{indent: indent, item: item}, level) do
    inner = "\n" <> String.duplicate(indent, level + 1)
    {inner, item <> inner, "\n" <> String.duplicate(indent, level)}
  end

  defp sort_pairs(pairs) do
    Enum.sort(pairs, fn {left, _}, {right, _} -> not Value.compare(:lt, right, left) end)
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_float(key), do: Value.format_float(key)
  defp key_string(key) when is_integer(key), do: Integer.to_string(key)
  defp key_string(true), do: "true"
  defp key_string(false), do: "false"
  defp key_string(nil), do: "null"

  defp key_string(key) do
    raise Otera.Error,
      kind: :type_error,
      message: "keys must be str, int, float, bool or None, not #{Value.type_name(key)}"
  end

  defp encode_string(string, ascii), do: [?", escape(string, ascii, []), ?"]

  defp escape("", _ascii, acc), do: Enum.reverse(acc)
  defp escape("\"" <> rest, ascii, acc), do: escape(rest, ascii, ["\\\"" | acc])
  defp escape("\\" <> rest, ascii, acc), do: escape(rest, ascii, ["\\\\" | acc])
  defp escape("\n" <> rest, ascii, acc), do: escape(rest, ascii, ["\\n" | acc])
  defp escape("\r" <> rest, ascii, acc), do: escape(rest, ascii, ["\\r" | acc])
  defp escape("\t" <> rest, ascii, acc), do: escape(rest, ascii, ["\\t" | acc])
  defp escape("\b" <> rest, ascii, acc), do: escape(rest, ascii, ["\\b" | acc])
  defp escape("\f" <> rest, ascii, acc), do: escape(rest, ascii, ["\\f" | acc])

  defp escape(<<char, rest::binary>>, ascii, acc) when char < 0x20,
    do: escape(rest, ascii, [unicode_escape(char) | acc])

  defp escape(<<char, rest::binary>>, true, acc) when char == 0x7F,
    do: escape(rest, true, [unicode_escape(char) | acc])

  defp escape(<<char, rest::binary>>, ascii, acc) when char < 0x80,
    do: escape(rest, ascii, [char | acc])

  defp escape(<<char::utf8, rest::binary>>, true, acc) when char > 0xFFFF do
    code = char - 0x10000
    high = 0xD800 + Bitwise.bsr(code, 10)
    low = 0xDC00 + Bitwise.band(code, 0x3FF)
    escape(rest, true, [unicode_escape(low), unicode_escape(high) | acc])
  end

  defp escape(<<char::utf8, rest::binary>>, true, acc),
    do: escape(rest, true, [unicode_escape(char) | acc])

  defp escape(<<char::utf8, rest::binary>>, false, acc),
    do: escape(rest, false, [<<char::utf8>> | acc])

  defp unicode_escape(char),
    do:
      "\\u" <> (char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
end
