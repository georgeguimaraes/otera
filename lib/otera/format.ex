defmodule Otera.Format do
  @moduledoc """
  Python string formatting: the `%` operator, which the `format` filter of Jinja2 uses, and `str.format()`.

  Both support the conversions and the format specification that templates use: fill, alignment, sign, width, precision, and the types `s`, `r`, `d`, `i`, `f`, `e`, `g`, `x`, `o`, `b`, `c` and `%`.
  """

  alias Otera.{Dict, Value}

  @printf_regex ~r/\A(?:\(([^)]*)\))?([-+ #0]*)(\*|\d+)?(?:\.(\*|\d+))?[hlL]?(.?)/su
  @printf_types ~w(d i o u x X e E f F g G c r s a)
  @spec_regex ~r/\A(?:(?<fill>.)?(?<align>[<>=^]))?(?<sign>[-+ ])?(?<alternate>#)?(?<zero>0)?(?<width>\d+)?(?<grouping>[,_])?(?:\.(?<precision>\d+))?(?<type>[bcdeEfFgGnosxX%])?\z/su

  @doc """
  Formats `args` into `format` with the rules of the Python `%` operator.
  """
  @spec printf(String.t(), term) :: String.t()
  def printf(format, args) do
    # Like Python, a dict or a list is one argument that is also a mapping, so extra arguments are no error.
    {positional, mapping} =
      case args do
        args when is_tuple(args) -> {Tuple.to_list(args), nil}
        args when is_struct(args, Dict) or is_list(args) -> {[args], args}
        arg -> {[arg], nil}
      end

    {output, rest} = printf(format, format, positional, mapping, [])

    if rest != [] and mapping == nil,
      do: fail(:type_error, "not all arguments converted during string formatting")

    IO.iodata_to_binary(output)
  end

  defp printf("", _format, args, _mapping, acc), do: {Enum.reverse(acc), args}

  defp printf("%%" <> rest, format, args, mapping, acc),
    do: printf(rest, format, args, mapping, ["%" | acc])

  defp printf("%" <> rest, format, args, mapping, acc) do
    case Regex.run(@printf_regex, rest) do
      [spec, key, flags, width, precision, type] when type in @printf_types ->
        {width, args} = star(width, args)
        {precision, args} = star(precision, args)
        {value, args} = printf_arg(key, args, mapping)
        text = printf_value(value, flags, width, precision, type)
        rest = binary_part(rest, byte_size(spec), byte_size(rest) - byte_size(spec))
        printf(rest, format, args, mapping, [text | acc])

      [_spec, _key, _flags, _width, _precision, ""] ->
        fail(:value_error, "incomplete format")

      [spec | _] ->
        <<char::utf8>> = String.last(spec)
        index = Value.str_length(format) - Value.str_length(rest) + Value.str_length(spec) - 1
        hex = char |> Integer.to_string(16) |> String.downcase()

        fail(
          :value_error,
          "unsupported format character #{Value.repr(<<char::utf8>>)} (0x#{hex}) at index #{index}"
        )
    end
  end

  defp printf(<<char::utf8, rest::binary>>, format, args, mapping, acc),
    do: printf(rest, format, args, mapping, [<<char::utf8>> | acc])

  defp printf_arg("", [], _mapping),
    do: fail(:type_error, "not enough arguments for format string")

  defp printf_arg("", [arg | args], _mapping), do: {arg, args}

  defp printf_arg(key, args, %Dict{} = mapping) do
    case Dict.fetch(mapping, key) do
      {:ok, value} -> {value, args}
      :error -> fail(:key_error, Value.repr(key))
    end
  end

  defp printf_arg(_key, _args, _mapping), do: fail(:type_error, "format requires a mapping")

  defp star("*", [width | args]), do: {width, args}
  defp star("", args), do: {nil, args}
  defp star(digits, args), do: {String.to_integer(digits), args}

  defp printf_value(value, flags, width, precision, type) do
    align = if String.contains?(flags, "-"), do: "<", else: ">"
    zero = String.contains?(flags, "0") and align == ">" and type not in ["s", "r", "a", "c"]

    spec = %{
      fill: if(zero, do: "0", else: " "),
      align: if(zero, do: "=", else: align),
      sign: printf_sign(flags),
      alternate: String.contains?(flags, "#"),
      width: width,
      grouping: nil,
      precision: precision,
      type: printf_type(type)
    }

    printf_convert(value, type, spec)
  end

  defp printf_sign(flags) do
    cond do
      String.contains?(flags, "+") -> "+"
      String.contains?(flags, " ") -> " "
      true -> "-"
    end
  end

  defp printf_convert(value, "s", spec),
    do: pad(truncate(Value.to_str(value), spec.precision), spec)

  defp printf_convert(value, "r", spec),
    do: pad(truncate(Value.repr(value), spec.precision), spec)

  defp printf_convert(value, "a", spec), do: pad(truncate(ascii(value), spec.precision), spec)
  defp printf_convert(value, "c", spec) when is_integer(value), do: pad(<<value::utf8>>, spec)
  defp printf_convert(<<_::utf8>> = value, "c", spec), do: pad(value, spec)
  defp printf_convert(_value, "c", _spec), do: fail(:type_error, "%c requires int or char")

  defp printf_convert(value, type, spec) when type in ["d", "i", "u"],
    do: format_number(printf_integer(value, type), spec)

  defp printf_convert(value, type, spec), do: format_number(printf_number(value, type), spec)

  defp printf_type(type) when type in ["i", "u"], do: "d"
  defp printf_type(type), do: type

  defp printf_integer(value, _type) when is_integer(value), do: value
  defp printf_integer(value, _type) when is_boolean(value), do: if(value, do: 1, else: 0)
  defp printf_integer(value, _type) when is_float(value), do: trunc(value)

  defp printf_integer(value, type),
    do:
      fail(
        :type_error,
        "%#{type} format: a real number is required, not #{Value.type_name(value)}"
      )

  defp printf_number(value, type)
       when is_integer(value) or (is_float(value) and type not in ["x", "X", "o"]),
       do: value

  defp printf_number(value, _type) when is_boolean(value), do: if(value, do: 1, else: 0)

  defp printf_number(value, type) when type in ["x", "X", "o"],
    do:
      fail(:type_error, "%#{type} format: an integer is required, not #{Value.type_name(value)}")

  defp printf_number(value, _type),
    do: fail(:type_error, "must be real number, not #{Value.type_name(value)}")

  @doc """
  Formats `args` and `kwargs` into `format` with the rules of Python `str.format()`.
  """
  @spec format(String.t(), list, Dict.t()) :: String.t()
  def format(format, args, kwargs) do
    {output, _index} = format_fields(format, args, kwargs, 0, [])
    IO.iodata_to_binary(output)
  end

  defp format_fields("", _args, _kwargs, index, acc), do: {Enum.reverse(acc), index}

  defp format_fields("{{" <> rest, args, kwargs, index, acc),
    do: format_fields(rest, args, kwargs, index, ["{" | acc])

  defp format_fields("}}" <> rest, args, kwargs, index, acc),
    do: format_fields(rest, args, kwargs, index, ["}" | acc])

  defp format_fields("{" <> rest, args, kwargs, index, acc) do
    {field, rest} = field_text(rest, 0, "")
    {name, conversion, spec} = split_field(field)
    {value, index} = field_value(name, args, kwargs, index)

    value =
      case conversion do
        "r" -> Value.repr(value)
        "s" -> Value.to_str(value)
        "a" -> ascii(value)
        nil -> value
        other -> fail(:value_error, "Unknown conversion specifier #{other}")
      end

    {spec, index} = nested_spec(spec, args, kwargs, index)
    format_fields(rest, args, kwargs, index, [format_value(value, spec) | acc])
  end

  defp format_fields("}" <> _rest, _args, _kwargs, _index, _acc),
    do: fail(:value_error, "Single '}' encountered in format string")

  defp format_fields(<<char::utf8, rest::binary>>, args, kwargs, index, acc),
    do: format_fields(rest, args, kwargs, index, [<<char::utf8>> | acc])

  defp field_text("", 0, ""), do: fail(:value_error, "Single '{' encountered in format string")
  defp field_text("", _depth, _acc), do: fail(:value_error, "expected '}' before end of string")
  defp field_text("}" <> rest, 0, acc), do: {acc, rest}
  defp field_text("}" <> rest, depth, acc), do: field_text(rest, depth - 1, acc <> "}")
  defp field_text("{" <> rest, depth, acc), do: field_text(rest, depth + 1, acc <> "{")

  defp field_text(<<char::utf8, rest::binary>>, depth, acc),
    do: field_text(rest, depth, acc <> <<char::utf8>>)

  defp split_field(field) do
    [name_and_conversion | spec] = String.split(field, ":", parts: 2)

    case String.split(name_and_conversion, "!", parts: 2) do
      [name, conversion] -> {name, conversion, Enum.join(spec)}
      [name] -> {name, nil, Enum.join(spec)}
    end
  end

  defp nested_spec(spec, args, kwargs, index) do
    if String.contains?(spec, "{") do
      {output, index} = format_fields(spec, args, kwargs, index, [])
      {IO.iodata_to_binary(output), index}
    else
      {spec, index}
    end
  end

  defp field_value(name, args, kwargs, index) do
    [first | path] = Regex.split(~r/(?=[.\[])/, name)

    {value, index} =
      cond do
        first == "" -> {positional(args, index), index + 1}
        first =~ ~r/\A\d+\z/ -> {positional(args, String.to_integer(first)), index}
        true -> {keyword(kwargs, first), index}
      end

    {Enum.reduce(path, value, &lookup/2), index}
  end

  defp positional(args, index) do
    case Enum.fetch(args, index) do
      {:ok, value} ->
        value

      :error ->
        fail(:index_error, "tuple index out of range")
    end
  end

  defp keyword(kwargs, name) do
    case Dict.fetch(kwargs, name) do
      {:ok, value} -> value
      :error -> fail(:key_error, Value.repr(name))
    end
  end

  defp lookup("." <> attr, value), do: Value.getattr(value, attr)

  defp lookup("[" <> key, value) do
    key = String.trim_trailing(key, "]")
    Value.getitem(value, if(key =~ ~r/\A\d+\z/, do: String.to_integer(key), else: key))
  end

  defp format_value(value, ""), do: Value.to_str(value)

  defp format_value(value, spec) do
    case Regex.named_captures(@spec_regex, spec) do
      nil ->
        fail(
          :value_error,
          "Invalid format specifier '#{spec}' for object of type '#{Value.type_name(value)}'"
        )

      captures ->
        spec = parse_spec(captures)

        cond do
          is_binary(value) ->
            pad(truncate(value, spec.precision), %{spec | type: "s"})

          is_number(value) or is_boolean(value) ->
            format_number(value, spec)

          true ->
            fail(
              :type_error,
              "unsupported format string passed to #{Value.type_name(value)}.__format__"
            )
        end
    end
  end

  defp parse_spec(captures) do
    {fill, align} = fill_align(captures["fill"], captures["align"], captures["zero"])

    %{
      fill: fill,
      align: align,
      sign: present(captures["sign"]) || "-",
      alternate: captures["alternate"] != "",
      width: integer(captures["width"]),
      grouping: present(captures["grouping"]),
      precision: integer(captures["precision"]),
      type: present(captures["type"])
    }
  end

  defp fill_align("", align, _zero) when align != "", do: {" ", align}
  defp fill_align(fill, align, _zero) when align != "", do: {fill, align}
  defp fill_align(_fill, "", "0"), do: {"0", "="}
  defp fill_align(_fill, "", _zero), do: {" ", nil}

  defp present(""), do: nil
  defp present(text), do: text

  defp integer(""), do: nil
  defp integer(digits), do: String.to_integer(digits)

  defp truncate(string, nil), do: string
  defp truncate(string, precision), do: Value.slice(string, 0, precision, nil)

  # Python ascii(): repr() with the non-ASCII characters escaped.
  defp ascii(value) do
    for <<char::utf8 <- Value.repr(value)>>, into: "" do
      cond do
        char < 0x80 -> <<char>>
        char <= 0xFF -> "\\x" <> hex(char, 2)
        char <= 0xFFFF -> "\\u" <> hex(char, 4)
        true -> "\\U" <> hex(char, 8)
      end
    end
  end

  defp hex(char, size),
    do: char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")

  defp format_number(value, %{type: type} = spec) when is_number(value) do
    {sign, digits} = number_digits(value, spec, type)
    digits = group(digits, spec.grouping, if(type in ["x", "X", "o", "b"], do: 4, else: 3))

    sign =
      cond do
        sign -> "-"
        spec.sign == "-" -> ""
        true -> spec.sign
      end

    pad_number(sign, digits, spec)
  end

  defp format_number(value, spec) when is_boolean(value),
    do: format_number(if(value, do: 1, else: 0), spec)

  defp format_number(value, spec),
    do:
      fail(
        :value_error,
        "Unknown format code '#{spec.type}' for object of type '#{Value.type_name(value)}'"
      )

  defp number_digits(value, _spec, "c") when is_integer(value), do: {false, <<value::utf8>>}

  defp number_digits(value, _spec, type) when type in [nil, "d", "n"] and is_integer(value),
    do: {value < 0, Integer.to_string(abs(value))}

  defp number_digits(value, _spec, type) when type in ["d", "n"],
    do:
      fail(
        :value_error,
        "Unknown format code '#{type}' for object of type '#{Value.type_name(value)}'"
      )

  defp number_digits(value, spec, type) when type in ["x", "X", "o", "b"] and is_integer(value) do
    base = %{"x" => 16, "X" => 16, "o" => 8, "b" => 2}[type]
    digits = Integer.to_string(abs(value), base)
    digits = if type == "x", do: String.downcase(digits), else: digits
    prefix = if spec.alternate, do: "0" <> String.downcase(type), else: ""
    {value < 0, prefix <> digits}
  end

  defp number_digits(value, _spec, nil) when is_float(value),
    do: {value < 0, Value.format_float(abs(value))}

  defp number_digits(value, spec, type) when type in ["f", "F", "%"] do
    value = if type == "%", do: value * 100, else: value
    digits = fixed(abs(value) * 1.0, spec.precision || 6)
    digits = if spec.alternate and spec.precision == 0, do: digits <> ".", else: digits
    {negative?(value), if(type == "%", do: digits <> "%", else: digits)}
  end

  defp number_digits(value, spec, type) when type in ["e", "E"] do
    digits = scientific(abs(value) * 1.0, spec.precision || 6)
    {negative?(value), if(type == "E", do: String.upcase(digits), else: digits)}
  end

  defp number_digits(value, spec, type) when type in ["g", "G"] do
    precision = max(spec.precision || 6, 1)
    value = value * 1.0
    [_, exponent] = String.split(scientific(abs(value), precision - 1), "e")
    exponent = String.to_integer(exponent)

    digits =
      if exponent >= -4 and exponent < precision,
        do: fixed(abs(value), precision - 1 - exponent),
        else: scientific(abs(value), precision - 1)

    digits =
      if spec.alternate,
        do: digits,
        else: Regex.replace(~r/\.0*(?=e|$)|(\.\d*?)0+(?=e|$)/, digits, "\\1")

    {negative?(value), if(type == "G", do: String.upcase(digits), else: digits)}
  end

  defp number_digits(value, _spec, type),
    do:
      fail(
        :value_error,
        "Unknown format code '#{type}' for object of type '#{Value.type_name(value)}'"
      )

  defp negative?(value) when is_float(value), do: value < 0 or <<value::float>> == <<-0.0::float>>
  defp negative?(value), do: value < 0

  @doc """
  Formats a non-negative float with `decimals` digits after the point, like Python `"%.<decimals>f"`. A negative `decimals` rounds to tens, hundreds and so on.

  The digits come from the exact value of the float, rounded half to even, as in Python.
  """
  @spec fixed(float, integer) :: String.t()
  def fixed(value, decimals) do
    digits = value |> round_digits(decimals) |> Integer.to_string()

    if decimals <= 0 do
      digits <> String.duplicate("0", -decimals)
    else
      {whole, fraction} =
        digits |> String.pad_leading(decimals + 1, "0") |> String.split_at(-decimals)

      whole <> "." <> fraction
    end
  end

  defp scientific(value, precision) do
    exponent = if value == 0, do: 0, else: Value.decimal_exponent(value)
    count = Integer.pow(10, precision + 1)

    {digits, exponent} =
      case round_digits(value, precision - exponent) do
        digits when digits >= count ->
          {round_digits(value, precision - exponent - 1), exponent + 1}

        digits ->
          {digits, exponent}
      end

    {first, rest} =
      digits
      |> Integer.to_string()
      |> String.pad_leading(precision + 1, "0")
      |> String.split_at(1)

    mantissa = if rest == "", do: first, else: first <> "." <> rest
    sign = if exponent < 0, do: "-", else: "+"
    mantissa <> "e" <> sign <> String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")
  end

  # Returns round(value * 10^decimals) as an integer, from the exact binary value, with ties to even.
  defp round_digits(value, decimals) do
    {mantissa, exponent} = exact(value)
    numerator = mantissa * Integer.pow(10, max(decimals, 0)) * Integer.pow(2, max(exponent, 0))
    denominator = Integer.pow(10, max(-decimals, 0)) * Integer.pow(2, max(-exponent, 0))
    quotient = div(numerator, denominator)
    twice_remainder = 2 * rem(numerator, denominator)

    cond do
      twice_remainder > denominator -> quotient + 1
      twice_remainder < denominator -> quotient
      true -> quotient + rem(quotient, 2)
    end
  end

  defp exact(value) do
    <<_sign::1, exponent::11, fraction::52>> = <<value::float>>

    if exponent == 0,
      do: {fraction, -1074},
      else: {fraction + Integer.pow(2, 52), exponent - 1075}
  end

  defp group(digits, nil, _size), do: digits

  defp group(digits, separator, size) do
    [whole | fraction] = String.split(digits, ".", parts: 2)

    grouped =
      whole
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(size)
      |> Enum.map_join(separator, &Enum.join/1)
      |> String.reverse()

    Enum.join([grouped | fraction], ".")
  end

  defp pad_number(sign, digits, %{align: "="} = spec) do
    width = (spec.width || 0) - Value.str_length(sign)
    sign <> String.pad_leading(digits, max(width, 0), spec.fill)
  end

  defp pad_number(sign, digits, spec), do: pad(sign <> digits, %{spec | align: spec.align || ">"})

  defp pad(string, %{width: nil}), do: string

  defp pad(string, spec) do
    count = max(spec.width - Value.str_length(string), 0)

    case spec.align || "<" do
      ">" ->
        String.duplicate(spec.fill, count) <> string

      "^" ->
        String.duplicate(spec.fill, div(count, 2)) <>
          string <> String.duplicate(spec.fill, count - div(count, 2))

      _ ->
        string <> String.duplicate(spec.fill, count)
    end
  end

  defp fail(kind, message), do: raise(Otera.Error, kind: kind, message: message)
end
