defmodule Otera.Pretty do
  @moduledoc """
  Python `pprint.pformat`, for the `pprint` filter, with its defaults: a width of 80, an indent of 1, and dicts sorted by key.

  A value whose `repr()` fits on its line prints as the `repr()`. A longer dict, list or tuple puts one item on each line, and a longer string splits into parts at whitespace, like Python.
  """

  alias Otera.{Dict, GroupTuple, Value}

  @width 80

  @doc """
  Formats `value` like `pprint.pformat(value)`.
  """
  @spec format(term) :: String.t()
  def format(value), do: value |> format(0, 0, 0) |> IO.iodata_to_binary()

  defp format(value, indent, allowance, level) do
    text = repr(value)

    if Value.str_length(text) > @width - indent - allowance,
      do: pretty(value, indent, allowance, level + 1) || text,
      else: text
  end

  defp pretty(%Dict{pairs: []}, _indent, _allowance, _level), do: "{}"

  defp pretty(%Dict{pairs: pairs}, indent, allowance, level) do
    indent = indent + 1
    items = sort_pairs(pairs)
    last = length(items) - 1

    lines =
      items
      |> Enum.with_index()
      |> Enum.map(fn {{key, value}, index} ->
        key = repr(key)

        [
          key,
          ": ",
          format(
            value,
            indent + Value.str_length(key) + 2,
            if(index == last, do: allowance + 1, else: 1),
            level
          )
        ]
      end)

    ["{", Enum.intersperse(lines, ",\n" <> String.duplicate(" ", indent)), "}"]
  end

  defp pretty(list, indent, allowance, level) when is_list(list),
    do: ["[", items(list, indent, allowance + 1, level), "]"]

  defp pretty(%GroupTuple{} = group, indent, allowance, level),
    do: pretty(GroupTuple.to_tuple(group), indent, allowance, level)

  defp pretty(tuple, indent, allowance, level) when is_tuple(tuple) do
    ending = if tuple_size(tuple) == 1, do: ",)", else: ")"
    ["(", items(Tuple.to_list(tuple), indent, allowance + String.length(ending), level), ending]
  end

  defp pretty("", _indent, _allowance, _level), do: nil

  defp pretty(string, indent, allowance, level) when is_binary(string),
    do: string_parts(string, indent, allowance, level)

  defp pretty(_value, _indent, _allowance, _level), do: nil

  defp items([], _indent, _allowance, _level), do: []

  defp items(items, indent, allowance, level) do
    indent = indent + 1
    last = length(items) - 1

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      format(item, indent, if(index == last, do: allowance, else: 1), level)
    end)
    |> Enum.intersperse(",\n" <> String.duplicate(" ", indent))
  end

  # Python splits a long string at whitespace into parts that fit, and puts the parts of a top-level string in parentheses.
  defp string_parts(string, indent, allowance, level) do
    {indent, allowance} =
      if level == 1, do: {indent + 1, allowance + 1}, else: {indent, allowance}

    max_width = @width - indent
    lines = Otera.Methods.call(string, "splitlines", [true], %Dict{})
    last_line = length(lines) - 1

    chunks =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, index} ->
        line_width = if index == last_line, do: max_width - allowance, else: max_width

        if Value.str_length(repr(line)) <= line_width,
          do: [repr(line)],
          else: line_chunks(line, max_width, allowance, index == last_line)
      end)

    case chunks do
      [_] ->
        repr(string)

      chunks ->
        joined = Enum.intersperse(chunks, "\n" <> String.duplicate(" ", indent))
        if level == 1, do: ["(", joined, ")"], else: joined
    end
  end

  defp line_chunks(line, max_width, allowance, last_line?) do
    parts = Regex.scan(~r/\S*\s*/u, line) |> List.flatten() |> Enum.reject(&(&1 == ""))
    last_part = length(parts) - 1

    {chunks, current} =
      parts
      |> Enum.with_index()
      |> Enum.reduce({[], ""}, fn {part, index}, {chunks, current} ->
        width = if index == last_part and last_line?, do: max_width - allowance, else: max_width
        candidate = current <> part

        cond do
          Value.str_length(repr(candidate)) <= width -> {chunks, candidate}
          current != "" -> {[repr(current) | chunks], part}
          true -> {chunks, part}
        end
      end)

    Enum.reverse(if current != "", do: [repr(current) | chunks], else: chunks)
  end

  # Like repr(), with the keys of dicts in sorted order.
  defp repr(%Dict{pairs: pairs}),
    do:
      "{" <>
        Enum.map_join(sort_pairs(pairs), ", ", fn {key, value} ->
          repr(key) <> ": " <> repr(value)
        end) <> "}"

  defp repr(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &repr/1) <> "]"
  defp repr({item}), do: "(" <> repr(item) <> ",)"

  defp repr(tuple) when is_tuple(tuple),
    do: "(" <> Enum.map_join(Tuple.to_list(tuple), ", ", &repr/1) <> ")"

  defp repr(%GroupTuple{} = group), do: group |> GroupTuple.to_tuple() |> repr()
  defp repr(value), do: Value.repr(value)

  # Python sorts the items by key, and orders the keys that it cannot compare by the name of their type.
  defp sort_pairs(pairs) do
    Enum.sort(pairs, fn {left, _}, {right, _} ->
      try do
        not Value.compare(:lt, right, left)
      rescue
        Otera.Error ->
          "<class '#{Value.type_name(left)}'>" <= "<class '#{Value.type_name(right)}'>"
      end
    end)
  end
end
