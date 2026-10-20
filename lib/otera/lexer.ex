defmodule Otera.Lexer do
  @moduledoc """
  Splits a template source into tokens, with the rules of the Python Jinja2 lexer.

  The lexer normalizes `\\r\\n` and `\\r` to `\\n`, and removes one trailing newline unless `keep_trailing_newline` is set. It applies the whitespace control of the tags: `-` strips all whitespace on that side, `+` keeps the whitespace that `lstrip_blocks` or `trim_blocks` would remove, `trim_blocks` removes the first newline after a block or comment tag, and `lstrip_blocks` removes the spaces and tabs before a block or comment tag at the start of a line. Comments do not make tokens, and the content of a raw block becomes text.

  A token is `{type, value, line}`. The types are `:data`, `:variable_begin`, `:variable_end`, `:block_begin`, `:block_end`, `:name`, `:string`, `:integer`, `:float`, `:operator` and `:eof`.
  """

  alias Otera.SyntaxError

  @type token :: {atom, term, pos_integer}

  @operators ["**", "//", "==", "!=", ">=", "<="] ++
               String.split("+ - / * % ~ [ ] ( ) { } > < = . : | , ;")
  @closing %{"(" => ")", "[" => "]", "{" => "}"}

  @whitespace ~r/\A\s+/u
  @float ~r/\A(?:\d+_)*\d+(?:(?:\.(?:\d+_)*\d+)?[eE][+\-]?(?:\d+_)*\d+|\.(?:\d+_)*\d+)/
  @integer ~r/\A(?:0[bB](?:_?[01])+|0[oO](?:_?[0-7])+|0[xX](?:_?[0-9a-fA-F])+|[1-9](?:_?\d)*|0(?:_?0)*)/
  @name ~r/\A[\p{L}\p{Nl}_][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}]*/u
  @string ~r/\A(?:'[^'\\]*(?:\\.[^'\\]*)*'|"[^"\\]*(?:\\.[^"\\]*)*")/s
  @raw_begin ~r/\A\s*raw\s*(?:-%}\s*|%})/u
  @raw_end ~r/{%([-+]?)\s*endraw\s*(?:\+%}|-%}\s*|%}(\n?))/u
  @only_whitespace ~r/\A\s+\z/u

  @doc """
  Returns the tokens of `source`. Raises `Otera.SyntaxError`.

  Options: `:trim_blocks`, `:lstrip_blocks` and `:keep_trailing_newline`, all `false` by default.
  """
  @spec tokenize(String.t(), keyword) :: [token]
  def tokenize(source, opts \\ []) do
    source = normalize_newlines(source, Keyword.get(opts, :keep_trailing_newline, false))

    state = %{
      source: source,
      trim: Keyword.get(opts, :trim_blocks, false),
      lstrip: Keyword.get(opts, :lstrip_blocks, false),
      line: 1,
      line_starting: true
    }

    root(source, [], state)
  end

  defp normalize_newlines(source, keep_trailing_newline) do
    source = String.replace(source, ["\r\n", "\r"], "\n")

    if not keep_trailing_newline and String.ends_with?(source, "\n"),
      do: binary_part(source, 0, byte_size(source) - 1),
      else: source
  end

  defp root(rest, acc, state) do
    case :binary.match(rest, ["{{", "{%", "{#"]) do
      :nomatch ->
        acc = emit_data(acc, rest, state.line)
        Enum.reverse([{:eof, nil, count_lines(state, rest).line} | acc])

      {pos, 2} ->
        text = binary_part(rest, 0, pos)
        after_begin = binary_part(rest, pos + 2, byte_size(rest) - pos - 2)
        {sign, after_sign} = split_sign(after_begin)
        kind = tag_kind(binary_part(rest, pos, 2), after_sign)
        stripped = strip_text(text, sign, kind, state)
        acc = emit_data(acc, stripped, state.line)
        state = count_lines(state, text)
        begin(kind, after_sign, acc, state)
    end
  end

  defp split_sign("-" <> rest), do: {"-", rest}
  defp split_sign("+" <> rest), do: {"+", rest}
  defp split_sign(rest), do: {"", rest}

  defp tag_kind("{{", _), do: :variable
  defp tag_kind("{#", _), do: :comment

  defp tag_kind("{%", after_sign),
    do: if(Regex.match?(@raw_begin, after_sign), do: :raw, else: :block)

  defp strip_text(text, "-", _kind, _state), do: python_rstrip(text)
  defp strip_text(text, "+", _kind, _state), do: text
  defp strip_text(text, _sign, :variable, _state), do: text
  defp strip_text(text, _sign, _kind, %{lstrip: false}), do: text

  defp strip_text(text, _sign, _kind, state) do
    line_start =
      case :binary.matches(text, "\n") do
        [] -> 0
        matches -> matches |> List.last() |> elem(0) |> Kernel.+(1)
      end

    last_line = binary_part(text, line_start, byte_size(text) - line_start)

    if (line_start > 0 or state.line_starting) and Regex.match?(@only_whitespace, last_line),
      do: binary_part(text, 0, line_start),
      else: text
  end

  defp begin(:comment, rest, acc, state) do
    case :binary.match(rest, "#}") do
      :nomatch ->
        fail("Missing end of comment tag", state)

      {pos, 2} ->
        {before_end, sign} = split_end_sign(binary_part(rest, 0, pos))
        after_end = binary_part(rest, pos + 2, byte_size(rest) - pos - 2)
        state = count_lines(state, before_end)
        {skipped, after_end} = after_tag_end(sign, after_end, state.trim)
        root(after_end, acc, finish_tag(state, "#}" <> skipped))
    end
  end

  defp begin(:raw, rest, acc, state) do
    [begin_match] = Regex.run(@raw_begin, rest)

    state = %{
      count_lines(state, begin_match)
      | line_starting: String.ends_with?(begin_match, "\n")
    }

    rest = binary_part(rest, byte_size(begin_match), byte_size(rest) - byte_size(begin_match))

    case Regex.run(@raw_end, rest, return: :index) do
      nil ->
        fail("Missing end of raw directive", state)

      [{pos, len}, {sign_pos, sign_len} | trim] ->
        text = binary_part(rest, 0, pos)
        sign = binary_part(rest, sign_pos, sign_len)
        end_tag = binary_part(rest, pos, len)
        acc = emit_data(acc, strip_text(text, sign, :raw, state), state.line)

        end_tag =
          if match?([{_, 1}], trim) and not state.trim,
            do: binary_part(end_tag, 0, len - 1),
            else: end_tag

        state = %{
          count_lines(count_lines(state, text), end_tag)
          | line_starting: String.ends_with?(end_tag, "\n")
        }

        consumed = pos + byte_size(end_tag)
        root(binary_part(rest, consumed, byte_size(rest) - consumed), acc, state)
    end
  end

  defp begin(kind, rest, acc, state) do
    type = if kind == :variable, do: :variable_begin, else: :block_begin
    tag(rest, kind, [], [{type, nil, state.line} | acc], state)
  end

  defp split_end_sign(text) do
    case :binary.last(<<0, text::binary>>) do
      ?- -> {binary_part(text, 0, byte_size(text) - 1), "-"}
      ?+ -> {binary_part(text, 0, byte_size(text) - 1), "+"}
      _ -> {text, ""}
    end
  end

  # Returns the whitespace that the end of a tag consumes, and the rest of the source.
  defp after_tag_end("-", rest, _trim) do
    case Regex.run(@whitespace, rest) do
      [space] -> {space, binary_part(rest, byte_size(space), byte_size(rest) - byte_size(space))}
      nil -> {"", rest}
    end
  end

  defp after_tag_end("", "\n" <> rest, true), do: {"\n", rest}
  defp after_tag_end(_sign, rest, _trim), do: {"", rest}

  defp finish_tag(state, end_text),
    do: %{count_lines(state, end_text) | line_starting: String.ends_with?(end_text, "\n")}

  defp tag(rest, kind, [], acc, state) when kind in [:block, :variable] do
    case end_of_tag(kind, rest) do
      {sign, after_end} ->
        {skipped, after_end} = after_tag_end(sign, after_end, kind == :block and state.trim)
        type = if kind == :variable, do: :variable_end, else: :block_end
        root(after_end, [{type, nil, state.line} | acc], finish_tag(state, skipped))

      nil ->
        tag_token(rest, kind, [], acc, state)
    end
  end

  defp tag(rest, kind, balance, acc, state), do: tag_token(rest, kind, balance, acc, state)

  defp end_of_tag(:block, "+%}" <> rest), do: {"+", rest}
  defp end_of_tag(:block, "-%}" <> rest), do: {"-", rest}
  defp end_of_tag(:block, "%}" <> rest), do: {"", rest}
  defp end_of_tag(:variable, "-}}" <> rest), do: {"-", rest}
  defp end_of_tag(:variable, "}}" <> rest), do: {"+", rest}
  defp end_of_tag(_kind, _rest), do: nil

  defp tag_token("", _kind, _balance, acc, state),
    do: Enum.reverse([{:eof, nil, state.line} | acc])

  defp tag_token(rest, kind, balance, acc, state) do
    case next_token(rest, state) do
      {:whitespace, text} ->
        tag(skip(rest, text), kind, balance, acc, count_lines(state, text))

      {:operator, op} ->
        balance = balance(op, balance, state)
        tag(skip(rest, op), kind, balance, [{:operator, op, state.line} | acc], state)

      {type, text, value} ->
        tag(
          skip(rest, text),
          kind,
          balance,
          [{type, value, state.line} | acc],
          count_lines(state, text)
        )
    end
  end

  defp skip(rest, text), do: binary_part(rest, byte_size(text), byte_size(rest) - byte_size(text))

  defp next_token(rest, state) do
    cond do
      match = run(@whitespace, rest) ->
        {:whitespace, match}

      match = not after_dot?(rest, state) && run(@float, rest) ->
        {:float, match, parse_float(match)}

      match = run(@integer, rest) ->
        {:integer, match, parse_integer(match)}

      match = run(@name, rest) ->
        {:name, match, match}

      match = run(@string, rest) ->
        {:string, match, unescape(binary_part(match, 1, byte_size(match) - 2), state)}

      op = Enum.find(@operators, &String.starts_with?(rest, &1)) ->
        {:operator, op}

      true ->
        [char | _] = String.codepoints(rest)

        position =
          state.source
          |> binary_part(0, byte_size(state.source) - byte_size(rest))
          |> codepoint_count()

        fail("unexpected char #{Otera.Value.repr(char)} at #{position}", state)
    end
  end

  defp run(regex, rest) do
    case Regex.run(regex, rest) do
      [match | _] -> match
      nil -> nil
    end
  end

  # The float rule of Jinja2 does not match right after a dot, so that `x.0.1` is two lookups.
  defp after_dot?(rest, state) do
    offset = byte_size(state.source) - byte_size(rest)
    offset > 0 and :binary.at(state.source, offset - 1) == ?.
  end

  defp balance(op, balance, _state) when op in ["(", "[", "{"], do: [@closing[op] | balance]
  defp balance(op, [op | balance], _state) when op in [")", "]", "}"], do: balance
  defp balance(op, [], state) when op in [")", "]", "}"], do: fail("unexpected '#{op}'", state)

  defp balance(op, [expected | _], state) when op in [")", "]", "}"],
    do: fail("unexpected '#{op}', expected '#{expected}'", state)

  defp balance(_op, balance, _state), do: balance

  defp parse_integer(text) do
    case String.downcase(String.replace(text, "_", "")) do
      "0b" <> digits -> String.to_integer(digits, 2)
      "0o" <> digits -> String.to_integer(digits, 8)
      "0x" <> digits -> String.to_integer(digits, 16)
      digits -> String.to_integer(digits)
    end
  end

  defp parse_float(text) do
    {float, ""} = text |> String.replace("_", "") |> Float.parse()
    float
  end

  # Python decodes string literals with the unicode-escape codec.
  defp unescape(text, state), do: text |> unescape([], state) |> IO.iodata_to_binary()

  defp unescape("", acc, _state), do: Enum.reverse(acc)
  defp unescape("\\\n" <> rest, acc, state), do: unescape(rest, acc, state)
  defp unescape("\\\\" <> rest, acc, state), do: unescape(rest, ["\\" | acc], state)
  defp unescape("\\'" <> rest, acc, state), do: unescape(rest, ["'" | acc], state)
  defp unescape("\\\"" <> rest, acc, state), do: unescape(rest, ["\"" | acc], state)
  defp unescape("\\a" <> rest, acc, state), do: unescape(rest, ["\a" | acc], state)
  defp unescape("\\b" <> rest, acc, state), do: unescape(rest, ["\b" | acc], state)
  defp unescape("\\f" <> rest, acc, state), do: unescape(rest, ["\f" | acc], state)
  defp unescape("\\n" <> rest, acc, state), do: unescape(rest, ["\n" | acc], state)
  defp unescape("\\r" <> rest, acc, state), do: unescape(rest, ["\r" | acc], state)
  defp unescape("\\t" <> rest, acc, state), do: unescape(rest, ["\t" | acc], state)
  defp unescape("\\v" <> rest, acc, state), do: unescape(rest, ["\v" | acc], state)
  defp unescape("\\x" <> rest, acc, state), do: unescape_hex(rest, 2, "x", acc, state)
  defp unescape("\\u" <> rest, acc, state), do: unescape_hex(rest, 4, "u", acc, state)
  defp unescape("\\U" <> rest, acc, state), do: unescape_hex(rest, 8, "U", acc, state)

  defp unescape(<<"\\", digit, _::binary>> = text, acc, state) when digit in ?0..?7 do
    [octal] = Regex.run(~r/\A\\([0-7]{1,3})/, text, capture: :all_but_first)
    unescape(skip(text, "\\" <> octal), [<<String.to_integer(octal, 8)::utf8>> | acc], state)
  end

  defp unescape(<<char::utf8, rest::binary>>, acc, state),
    do: unescape(rest, [<<char::utf8>> | acc], state)

  defp unescape_hex(rest, size, letter, acc, state) do
    with <<hex::binary-size(^size), rest::binary>> <- rest,
         true <- String.match?(hex, ~r/\A[0-9a-fA-F]+\z/) do
      unescape(rest, [<<String.to_integer(hex, 16)::utf8>> | acc], state)
    else
      _ -> fail("truncated \\#{letter}#{String.duplicate("X", size)} escape", state)
    end
  rescue
    ArgumentError -> fail("illegal Unicode character", state)
  end

  defp python_rstrip(text), do: Otera.Value.strip(text, nil, :trailing)

  defp emit_data(acc, "", _line), do: acc
  defp emit_data(acc, text, line), do: [{:data, text, line} | acc]

  defp count_lines(state, text), do: %{state | line: state.line + count_newlines(text)}

  defp count_newlines(text), do: text |> :binary.matches("\n") |> length()

  defp codepoint_count(text), do: text |> String.to_charlist() |> length()

  defp fail(message, state), do: raise(SyntaxError, message: message, line: state.line)
end
