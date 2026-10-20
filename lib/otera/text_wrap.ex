defmodule Otera.TextWrap do
  @moduledoc """
  Python `textwrap.wrap`, for the `wordwrap` filter, with the options that the filter uses: no tab expansion, no whitespace replacement, and whitespace dropped at the start and end of the lines.

  It splits the text into chunks of words and whitespace, at hyphens when `break_on_hyphens` is set, with the regular expressions of Python, and fills each line with as many chunks as fit in `width` code points.
  """

  alias Otera.Value

  @whitespace "[\\t\\n\\x{0B}\\x{0C}\\r ]"
  @word_punct "[\\w!\"'&.,?]"
  @letter "[^\\d\\W]"
  @no_whitespace "[^\\t\\n\\x{0B}\\x{0C}\\r ]"

  @word_separator Regex.compile!(
                    "(#{@whitespace}+" <>
                      "|(?<=#{@word_punct})-{2,}(?=\\w)" <>
                      "|#{@no_whitespace}+?(?:-(?:(?<=#{@letter}{2}-)|(?<=#{@letter}-#{@letter}-))(?=#{@letter}-?#{@letter})" <>
                      "|(?=#{@whitespace}|\\z)|(?<=#{@word_punct})(?=-{2,}\\w)))",
                    "u"
                  )
  @simple_separator Regex.compile!("(#{@whitespace}+)", "u")

  @doc """
  Wraps `text` into lines of at most `width` code points.
  """
  @spec wrap(String.t(), integer, boolean, boolean) :: [String.t()]
  def wrap(_text, width, _break_long_words, _break_on_hyphens) when width <= 0,
    do: raise(Otera.Error, kind: :value_error, message: "invalid width #{width} (must be > 0)")

  def wrap(text, width, break_long_words, break_on_hyphens) do
    separator = if break_on_hyphens, do: @word_separator, else: @simple_separator
    chunks = separator |> Regex.split(text, include_captures: true) |> Enum.reject(&(&1 == ""))
    lines(chunks, width, break_long_words, break_on_hyphens, [])
  end

  defp lines([], _width, _break_long, _break_hyphens, lines), do: Enum.reverse(lines)

  defp lines(chunks, width, break_long, break_hyphens, lines) do
    chunks = if lines != [] and blank?(hd(chunks)), do: tl(chunks), else: chunks
    {line, chunks} = fill(chunks, width, [], 0)

    {line, chunks} =
      case chunks do
        [chunk | _] ->
          if Value.str_length(chunk) > width,
            do: long_word(chunks, line, width, break_long, break_hyphens),
            else: {line, chunks}

        [] ->
          {line, chunks}
      end

    line = if line != [] and blank?(hd(line)), do: tl(line), else: line
    lines = if line == [], do: lines, else: [line |> Enum.reverse() |> Enum.join() | lines]
    lines(chunks, width, break_long, break_hyphens, lines)
  end

  # Takes chunks while they fit. The line is in reverse order.
  defp fill([chunk | rest] = chunks, width, line, length) do
    chunk_length = Value.str_length(chunk)

    if length + chunk_length <= width,
      do: fill(rest, width, [chunk | line], length + chunk_length),
      else: {line, chunks}
  end

  defp fill([], _width, line, _length), do: {line, []}

  defp long_word([chunk | rest] = chunks, line, width, break_long, break_hyphens) do
    space_left = max(width - Enum.sum(Enum.map(line, &Value.str_length/1)), 1)

    cond do
      break_long ->
        cut = cut_position(chunk, space_left, break_hyphens)
        {[Value.slice(chunk, 0, cut, nil) | line], [Value.slice(chunk, cut, nil, nil) | rest]}

      line == [] ->
        {[chunk], rest}

      true ->
        {line, chunks}
    end
  end

  # Python breaks a long word after its last hyphen that fits, when letters come before it.
  defp cut_position(chunk, space_left, true) do
    head = Value.slice(chunk, 0, space_left, nil)

    case :binary.matches(head, "-") do
      [] ->
        space_left

      matches ->
        {byte, _} = List.last(matches)
        hyphen = Value.str_length(binary_part(head, 0, byte))

        if hyphen > 0 and String.trim(binary_part(head, 0, byte), "-") != "",
          do: hyphen + 1,
          else: space_left
    end
  end

  defp cut_position(_chunk, space_left, false), do: space_left

  defp blank?(chunk), do: Value.strip(chunk, nil, :both) == ""
end
