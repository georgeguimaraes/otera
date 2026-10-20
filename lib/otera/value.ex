defmodule Otera.Value do
  @moduledoc """
  The Python semantics of template values.

  Templates see Elixir values as these Python values:

  | Elixir                            | Python                |
  | --------------------------------- | --------------------- |
  | `nil`, `true`, `false`            | `None`, `True`, `False` |
  | integer, float                    | `int`, `float`        |
  | binary                            | `str`                 |
  | `Otera.Markup`                    | `Markup`, a `str`     |
  | list, tuple                       | `list`, `tuple`       |
  | `Otera.Range`                     | `range`               |
  | map, `Otera.Dict`                 | `dict`                |
  | other atom                        | `str`                 |
  | function                          | a callable            |

  `from_elixir/1` converts the variables of a render to these values. A map becomes an `Otera.Dict` with its keys in sorted order, and atom keys become strings.

  This module gives the rules that Jinja2 takes from Python: truthiness, `str()` and `repr()`, equality and ordering, arithmetic, iteration, and attribute and item lookup in the immutable sandbox of transformers.
  """

  import Kernel, except: [length: 1]

  alias Otera.{Dict, Iterable, Loop, Macro, Markup, Method, Methods, Namespace, Undefined}

  @internal [
    Dict,
    Iterable,
    Undefined,
    Namespace,
    Macro,
    Loop,
    Method,
    Otera.Function,
    Otera.Bytes,
    Otera.Cycler,
    Otera.Joiner,
    Otera.GroupTuple,
    Markup,
    Otera.Range,
    Otera.Template,
    Otera.TemplateModule,
    Otera.TemplateReference,
    Otera.BlockReference
  ]

  @doc """
  Converts an Elixir value to a template value. See the module documentation.
  """
  @spec from_elixir(term) :: term
  def from_elixir(value) when value in [nil, true, false], do: value
  def from_elixir(value) when is_atom(value), do: Atom.to_string(value)
  def from_elixir(value) when is_list(value), do: Enum.map(value, &from_elixir/1)

  def from_elixir(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&from_elixir/1) |> List.to_tuple()

  def from_elixir(%Dict{pairs: pairs}),
    do: Dict.new(Enum.map(pairs, fn {key, value} -> {from_elixir(key), from_elixir(value)} end))

  def from_elixir(%module{} = value) when module in @internal, do: value
  def from_elixir(%_{} = struct), do: struct |> Map.from_struct() |> from_elixir()

  def from_elixir(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {from_elixir(key), from_elixir(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> then(&%Dict{pairs: &1})
  end

  def from_elixir(value), do: value

  @doc """
  Returns the truth value of `value`, like Python `bool()`.
  """
  @spec truthy?(term) :: boolean
  def truthy?(value) when value in [nil, false, "", [], {}], do: false
  def truthy?(value) when is_number(value), do: value != 0
  def truthy?(%Dict{pairs: pairs}), do: pairs != []
  def truthy?(%Undefined{}), do: false
  def truthy?(%Otera.Bytes{data: data}), do: data != ""
  def truthy?(%Markup{text: text}), do: text != ""
  def truthy?(%Otera.Range{} = range), do: Otera.Range.size(range) > 0
  def truthy?(%Iterable{items: items} = iterable), do: not Iterable.view?(iterable) or items != []
  def truthy?(_value), do: true

  @doc """
  Returns the name of the Python type of `value`, as in Python error messages.
  """
  @spec type_name(term) :: String.t()
  def type_name(nil), do: "NoneType"
  def type_name(:missing), do: "_MissingType"
  def type_name(value) when is_boolean(value), do: "bool"
  def type_name(value) when is_integer(value), do: "int"
  def type_name(value) when is_float(value), do: "float"
  def type_name(value) when is_binary(value), do: "str"
  def type_name(value) when is_list(value), do: "list"
  def type_name(value) when is_tuple(value), do: "tuple"
  def type_name(%Dict{}), do: "dict"
  def type_name(%Otera.Cycler{}), do: "Cycler"
  def type_name(%Otera.Joiner{}), do: "Joiner"
  def type_name(%Otera.GroupTuple{}), do: "_GroupTuple"
  def type_name(%Otera.Bytes{}), do: "bytes"
  def type_name(%Markup{}), do: "Markup"
  def type_name(%Otera.Range{}), do: "range"
  def type_name(%Otera.Template{}), do: "Template"
  def type_name(%Otera.TemplateModule{}), do: "TemplateModule"
  def type_name(%Otera.TemplateReference{}), do: "TemplateReference"
  def type_name(%Otera.BlockReference{}), do: "BlockReference"
  def type_name(%Iterable{type: type}), do: type
  def type_name(%Undefined{}), do: "Undefined"
  def type_name(%Namespace{}), do: "Namespace"
  def type_name(%Macro{}), do: "Macro"
  def type_name(%Loop{}), do: "LoopContext"
  def type_name(%Method{receiver: :builtins, name: "range"}), do: "function"

  def type_name(%Method{receiver: :builtins}), do: "type"
  def type_name(%Method{}), do: "builtin_function_or_method"
  def type_name(value) when is_function(value) or is_struct(value, Otera.Function), do: "function"

  @doc """
  Describes the type of `value` as Jinja2 does in undefined messages, for example `dict object`.
  """
  @spec object_type_repr(term) :: String.t()
  def object_type_repr(nil), do: "None"
  def object_type_repr(:missing), do: "jinja2.utils._MissingType object"
  def object_type_repr(%Namespace{}), do: "jinja2.utils.Namespace object"
  def object_type_repr(%Undefined{}), do: "jinja2.runtime.Undefined object"
  def object_type_repr(%Macro{}), do: "jinja2.runtime.Macro object"
  def object_type_repr(%Loop{}), do: "jinja2.runtime.LoopContext object"
  def object_type_repr(%Otera.TemplateModule{}), do: "jinja2.environment.TemplateModule object"
  def object_type_repr(%Otera.Template{}), do: "jinja2.environment.Template object"

  def object_type_repr(%module{} = value)
      when module in [Otera.TemplateReference, Otera.BlockReference],
      do: "jinja2.runtime.#{type_name(value)} object"

  def object_type_repr(%module{} = value) when module in [Otera.Cycler, Otera.Joiner],
    do: "jinja2.utils.#{type_name(value)} object"

  def object_type_repr(value), do: "#{type_name(value)} object"

  ## str() and repr()

  @doc """
  Converts `value` to a string, like Python `str()`.
  """
  @spec to_str(term) :: String.t()
  def to_str(value) when is_binary(value), do: value
  def to_str(%Markup{text: text}), do: text
  def to_str(%Otera.TemplateModule{body: body}), do: body
  def to_str(%Undefined{}), do: ""
  def to_str(value), do: repr(value)

  @doc """
  Returns the Python `repr()` of `value`.
  """
  @spec repr(term) :: String.t()
  def repr(%Otera.GroupTuple{} = group), do: group |> Otera.GroupTuple.to_tuple() |> repr()

  def repr(%module{} = value) when module in [Otera.Cycler, Otera.Joiner],
    do: "<#{object_type_repr(value)}>"

  def repr(nil), do: "None"
  # The `missing` of Jinja2, which a macro reads for a loop variable after the loop ends.
  def repr(:missing), do: "missing"
  def repr(true), do: "True"
  def repr(false), do: "False"
  def repr(value) when is_integer(value), do: Integer.to_string(value)
  def repr(value) when is_float(value), do: format_float(value)
  def repr(value) when is_binary(value), do: repr_string(value)
  def repr(%Markup{text: text}), do: "Markup(" <> repr_string(text) <> ")"
  def repr(%Otera.Range{} = range), do: Otera.Range.repr(range)

  # Python prints the memory address of a module or a template without a name, which Otera leaves out.
  def repr(%Otera.TemplateModule{name: nil}), do: "<TemplateModule memory>"
  def repr(%Otera.TemplateModule{name: name}), do: "<TemplateModule #{repr(name)}>"
  def repr(%Otera.Template{name: nil}), do: "<Template memory>"
  def repr(%Otera.Template{name: name}), do: "<Template #{repr(name)}>"
  def repr(%Otera.TemplateReference{name: name}), do: "<TemplateReference #{repr(name)}>"
  def repr(%Otera.BlockReference{}), do: "<jinja2.runtime.BlockReference object>"
  def repr(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &repr/1) <> "]"
  def repr({item}), do: "(" <> repr(item) <> ",)"

  def repr(value) when is_tuple(value),
    do: "(" <> Enum.map_join(Tuple.to_list(value), ", ", &repr/1) <> ")"

  def repr(%Dict{pairs: pairs}),
    do:
      "{" <>
        Enum.map_join(pairs, ", ", fn {key, value} -> repr(key) <> ": " <> repr(value) end) <> "}"

  def repr(%Undefined{}), do: "Undefined"
  def repr(%Otera.Bytes{} = bytes), do: Otera.Bytes.repr(bytes)

  def repr(%Iterable{type: type, items: items} = iterable),
    do: if(Iterable.view?(iterable), do: "#{type}(#{repr(items)})", else: "<#{type} object>")

  def repr(%Namespace{} = namespace), do: "<Namespace #{repr(Namespace.attributes(namespace))}>"
  def repr(%Macro{name: nil}), do: "<Macro anonymous>"
  def repr(%Macro{name: name}), do: "<Macro #{repr(name)}>"
  def repr(%Loop{} = loop), do: "<LoopContext #{loop.index0 + 1}/#{Loop.get(loop, "length")}>"

  def repr(%Method{receiver: :builtins, name: name}) do
    case name do
      "range" -> "<function safe_range>"
      "dict" -> "<class 'dict'>"
      "namespace" -> "<class 'jinja2.utils.Namespace'>"
    end
  end

  def repr(%Method{name: name, receiver: receiver}),
    do: "<built-in method #{name} of #{type_name(receiver)} object>"

  def repr(%Otera.Function{name: name}), do: "<function #{name}>"
  def repr(value) when is_function(value), do: "<function #{inspect(value)}>"

  defp repr_string(string) do
    quote =
      if String.contains?(string, "'") and not String.contains?(string, "\""), do: ?", else: ?'

    escaped = for <<char::utf8 <- string>>, into: "", do: escape_char(char, quote)
    <<quote, escaped::binary, quote>>
  end

  defp escape_char(char, quote) when char in [quote, ?\\], do: <<?\\, char>>
  defp escape_char(?\t, _quote), do: "\\t"
  defp escape_char(?\n, _quote), do: "\\n"
  defp escape_char(?\r, _quote), do: "\\r"
  defp escape_char(char, _quote) when char < 0x20 or char == 0x7F, do: hex_escape(char)
  defp escape_char(char, _quote) when char < 0x7F, do: <<char>>

  defp escape_char(char, _quote) do
    if Otera.Unicode.printable?(char), do: <<char::utf8>>, else: hex_escape(char)
  end

  defp hex_escape(char) when char <= 0xFF, do: "\\x" <> hex(char, 2)
  defp hex_escape(char) when char <= 0xFFFF, do: "\\u" <> hex(char, 4)
  defp hex_escape(char), do: "\\U" <> hex(char, 8)

  defp hex(char, size),
    do: char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")

  @doc """
  Formats a float like Python `repr()`: the shortest digits that give the same float, in fixed notation from `1e-4` to below `1e16`, else in scientific notation.
  """
  @spec format_float(float) :: String.t()
  def format_float(float) when float == 0,
    do: if(<<float::float>> == <<0.0::float>>, do: "0.0", else: "-0.0")

  def format_float(float) do
    {digits, exponent} = float |> abs() |> shortest_digits()
    sign = if float < 0, do: "-", else: ""
    # The decimal point is after `point` digits: the value is 0.<digits> * 10^point.
    point = exponent + byte_size(digits)
    sign <> format_digits(digits, point)
  end

  defp format_digits(digits, point) when point > 16 or point < -3 do
    exponent = point - 1
    <<first, rest::binary>> = digits
    mantissa = if rest == "", do: <<first>>, else: <<first, ?., rest::binary>>
    sign = if exponent < 0, do: "-", else: "+"
    mantissa <> "e" <> sign <> String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")
  end

  defp format_digits(digits, point) when point <= 0,
    do: "0." <> String.duplicate("0", -point) <> digits

  defp format_digits(digits, point) when point >= byte_size(digits),
    do: digits <> String.duplicate("0", point - byte_size(digits)) <> ".0"

  defp format_digits(digits, point),
    do:
      binary_part(digits, 0, point) <>
        "." <> binary_part(digits, point, byte_size(digits) - point)

  @doc """
  Returns the decimal exponent of the first significant digit of a positive float, like `floor(log10(value))`.
  """
  @spec decimal_exponent(float) :: integer
  def decimal_exponent(value) do
    {digits, exponent} = shortest_digits(value)
    exponent + byte_size(digits) - 1
  end

  # Returns the shortest decimal digits of a positive float, and the exponent of the last digit.
  defp shortest_digits(float) do
    [mantissa, exponent] =
      case String.split(:erlang.float_to_binary(float, [:short]), "e") do
        [mantissa, exponent] -> [mantissa, String.to_integer(exponent)]
        [mantissa] -> [mantissa, 0]
      end

    [whole, fraction] = String.split(mantissa, ".")
    digits = String.trim_leading(whole <> fraction, "0")
    exponent = exponent - byte_size(fraction)
    trimmed = String.trim_trailing(digits, "0")
    {trimmed, exponent + byte_size(digits) - byte_size(trimmed)}
  end

  ## Strings

  @doc """
  Strips `chars` from one or both ends of `string`, like Python `str.strip()`. With `nil`, strips whitespace.
  """
  @spec strip(String.t(), String.t() | nil, :both | :leading | :trailing) :: String.t()
  def strip(string, chars, side) do
    strip? =
      if chars,
        do: &(&1 in String.to_charlist(chars)),
        else: &Otera.Unicode.space?/1

    codepoints = String.to_charlist(string)

    codepoints =
      if side in [:both, :leading],
        do: Enum.drop_while(codepoints, strip?),
        else: codepoints

    codepoints =
      if side in [:both, :trailing],
        do: codepoints |> Enum.reverse() |> Enum.drop_while(strip?) |> Enum.reverse(),
        else: codepoints

    List.to_string(codepoints)
  end

  @doc """
  Returns the number of code points in `string`, the length of a Python `str`.
  """
  @spec str_length(String.t()) :: non_neg_integer
  def str_length(string), do: string |> String.to_charlist() |> length()

  ## Equality and ordering

  @doc """
  Returns true if `left == right` in Python.
  """
  @spec equal?(term, term) :: boolean
  def equal?(%Markup{text: left}, right), do: equal?(left, right)
  def equal?(left, %Markup{text: right}), do: equal?(left, right)

  # Two ranges are equal when they give the same items.
  def equal?(%Otera.Range{} = left, %Otera.Range{} = right) do
    size = Otera.Range.size(left)

    size == Otera.Range.size(right) and
      (size == 0 or
         (left.start == right.start and (size == 1 or left.step == right.step)))
  end

  def equal?(%Otera.GroupTuple{} = left, right),
    do: equal?(Otera.GroupTuple.to_tuple(left), right)

  def equal?(left, %Otera.GroupTuple{} = right),
    do: equal?(left, Otera.GroupTuple.to_tuple(right))

  def equal?(left, right) when is_number(left) and is_number(right), do: left == right

  def equal?(left, right) when is_boolean(left) or is_boolean(right),
    do: number(left) == number(right)

  def equal?(left, right) when is_list(left) and is_list(right),
    do: length(left) == length(right) and Enum.zip_with(left, right, &equal?/2) |> Enum.all?()

  def equal?(left, right) when is_tuple(left) and is_tuple(right),
    do: equal?(Tuple.to_list(left), Tuple.to_list(right))

  def equal?(%Dict{pairs: left}, %Dict{pairs: right} = dict) do
    length(left) == length(right) and
      Enum.all?(left, fn {key, value} ->
        case Dict.fetch(dict, key) do
          {:ok, other} -> equal?(value, other)
          :error -> false
        end
      end)
  end

  def equal?(%Undefined{}, %Undefined{}), do: true
  def equal?(left, right), do: left === right

  defp number(true), do: 1
  defp number(false), do: 0
  defp number(value), do: value

  @doc """
  Compares two values with a Python ordering operator: `:lt`, `:lteq`, `:gt` or `:gteq`.
  """
  @spec compare(atom, term, term) :: boolean
  def compare(op, %Undefined{} = undefined, _right) when op in [:lt, :lteq, :gt, :gteq],
    do: Undefined.fail(undefined)

  def compare(op, _left, %Undefined{} = undefined) when op in [:lt, :lteq, :gt, :gteq],
    do: Undefined.fail(undefined)

  def compare(op, left, right) do
    case order(left, right) do
      {:error, left, right} ->
        symbol = %{lt: "<", lteq: "<=", gt: ">", gteq: ">="}[op]

        raise Otera.Error,
          kind: :type_error,
          message:
            "'#{symbol}' not supported between instances of '#{type_name(left)}' and '#{type_name(right)}'"

      order ->
        case op do
          :lt -> order == :lt
          :lteq -> order != :gt
          :gt -> order == :gt
          :gteq -> order != :lt
        end
    end
  end

  # Returns :lt, :eq or :gt for values that Python can order. For sequences, Python compares
  # the first items that differ, so an error names the types of those items.
  defp order(%Markup{text: left}, right) when is_binary(right) or is_struct(right, Markup),
    do: order(left, right)

  defp order(left, %Markup{text: right}) when is_binary(left), do: order(left, right)
  defp order(%Otera.GroupTuple{} = left, right), do: order(Otera.GroupTuple.to_tuple(left), right)
  defp order(left, %Otera.GroupTuple{} = right), do: order(left, Otera.GroupTuple.to_tuple(right))

  defp order(left, right)
       when (is_number(left) or is_boolean(left)) and (is_number(right) or is_boolean(right)),
       do: order_terms(number(left), number(right))

  defp order(left, right) when is_binary(left) and is_binary(right), do: order_terms(left, right)
  defp order(left, right) when is_list(left) and is_list(right), do: order_sequences(left, right)

  defp order(left, right) when is_tuple(left) and is_tuple(right),
    do: order_sequences(Tuple.to_list(left), Tuple.to_list(right))

  defp order(left, right), do: {:error, left, right}

  defp order_terms(left, right) when left < right, do: :lt
  defp order_terms(left, right) when left > right, do: :gt
  defp order_terms(_left, _right), do: :eq

  defp order_sequences([], []), do: :eq
  defp order_sequences([], _right), do: :lt
  defp order_sequences(_left, []), do: :gt

  defp order_sequences([left | left_rest], [right | right_rest]) do
    if equal?(left, right), do: order_sequences(left_rest, right_rest), else: order(left, right)
  end

  ## Arithmetic

  @doc """
  Applies a Python binary operator: `:add`, `:sub`, `:mul`, `:div`, `:floordiv`, `:mod` or `:pow`.
  """
  @spec binary_op(atom, term, term) :: term
  def binary_op(_op, %Undefined{} = undefined, _right), do: Undefined.fail(undefined)
  def binary_op(_op, _left, %Undefined{} = undefined), do: Undefined.fail(undefined)

  def binary_op(op, left, right) when is_boolean(left) or is_boolean(right) do
    if (numeric?(left) and numeric?(right)) or op == :mul,
      do: binary_op(op, number(left), number(right)),
      else: arithmetic(op, left, right)
  end

  # markupsafe: `+` escapes a plain string, `%` escapes the arguments, and `*` keeps the Markup.
  def binary_op(:add, %Markup{} = left, right) when is_binary(right) or is_struct(right, Markup),
    do: Markup.new(left.text <> Markup.escape(right).text)

  def binary_op(:add, left, %Markup{} = right) when is_binary(left),
    do: Markup.new(Markup.escape(left).text <> right.text)

  def binary_op(:mul, %Markup{} = left, right) when is_integer(right),
    do: Markup.map(left, &binary_op(:mul, &1, right))

  def binary_op(:mul, left, %Markup{} = right) when is_integer(left),
    do: binary_op(:mul, right, left)

  def binary_op(:mod, %Markup{} = left, right),
    do: Markup.map(left, &Otera.Format.printf(&1, right, true))

  def binary_op(op, left, right) do
    arithmetic(op, left, right)
  rescue
    ArithmeticError ->
      {kind, message} = arithmetic_error(op, left, right)
      reraise Otera.Error, [kind: kind, message: message], __STACKTRACE__
  end

  # Python raises these errors, or gives inf, nan or a complex number, which Elixir floats do not have.
  defp arithmetic_error(:pow, left, right) when left < 0 and is_float(right),
    do: {:not_implemented_error, "Otera does not support complex numbers"}

  defp arithmetic_error(:pow, _left, _right), do: {:overflow_error, "(34, 'Result too large')"}

  defp arithmetic_error(:div, left, right) when is_integer(left) and is_integer(right),
    do: {:overflow_error, "integer division result too large for a float"}

  defp arithmetic_error(_op, left, right) do
    if Enum.any?([left, right], &(is_integer(&1) and not float?(&1))),
      do: {:overflow_error, "int too large to convert to float"},
      else: {:not_implemented_error, "Otera does not support the floats inf and nan"}
  end

  defp float?(integer) do
    is_float(integer * 1.0)
  rescue
    ArithmeticError -> false
  end

  defp arithmetic(:add, left, right) when is_number(left) and is_number(right), do: left + right
  defp arithmetic(:add, left, right) when is_binary(left) and is_binary(right), do: left <> right
  defp arithmetic(:add, left, right) when is_list(left) and is_list(right), do: left ++ right

  defp arithmetic(:add, left, right) when is_tuple(left) and is_tuple(right),
    do: List.to_tuple(Tuple.to_list(left) ++ Tuple.to_list(right))

  defp arithmetic(:add, left, right) when is_binary(left) or is_list(left) or is_tuple(left) do
    type = type_name(left)

    raise Otera.Error,
      kind: :type_error,
      message: "can only concatenate #{type} (not \"#{type_name(right)}\") to #{type}"
  end

  defp arithmetic(:sub, left, right) when is_number(left) and is_number(right), do: left - right
  defp arithmetic(:mul, left, right) when is_number(left) and is_number(right), do: left * right

  defp arithmetic(:mul, left, right) when is_integer(left) and not is_number(right),
    do: arithmetic(:mul, right, left)

  defp arithmetic(:mul, left, right) when is_binary(left) and is_integer(right),
    do: String.duplicate(left, max(right, 0))

  defp arithmetic(:mul, left, right) when is_list(left) and is_integer(right),
    do: left |> List.duplicate(max(right, 0)) |> Enum.concat()

  defp arithmetic(:mul, left, right) when is_tuple(left) and is_integer(right),
    do: left |> Tuple.to_list() |> then(&arithmetic(:mul, &1, right)) |> List.to_tuple()

  defp arithmetic(:mul, left, right) when is_binary(left) or is_list(left) or is_tuple(left),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "can't multiply sequence by non-int of type '#{type_name(right)}'"
      )

  defp arithmetic(:div, left, right) when is_number(left) and is_number(right) do
    if right == 0,
      do:
        zero_division(
          if(is_float(left) or is_float(right),
            do: "float division by zero",
            else: "division by zero"
          )
        )

    left / right
  end

  defp arithmetic(:floordiv, left, right) when is_integer(left) and is_integer(right) do
    if right == 0, do: zero_division("integer division or modulo by zero")
    Integer.floor_div(left, right)
  end

  defp arithmetic(:floordiv, left, right) when is_number(left) and is_number(right) do
    if right == 0, do: zero_division("float floor division by zero")
    Float.floor(left / right) * 1.0
  end

  defp arithmetic(:mod, left, right) when is_integer(left) and is_integer(right) do
    if right == 0, do: zero_division("integer modulo by zero")
    Integer.mod(left, right)
  end

  defp arithmetic(:mod, left, right) when is_number(left) and is_number(right) do
    if right == 0, do: zero_division("float modulo")
    left - right * Float.floor(left / right)
  end

  defp arithmetic(:mod, left, right) when is_binary(left), do: Otera.Format.printf(left, right)

  defp arithmetic(:pow, left, right) when is_integer(left) and is_integer(right) and right >= 0,
    do: Integer.pow(left, right)

  defp arithmetic(:pow, left, right) when is_number(left) and is_number(right) do
    if left == 0 and right < 0, do: zero_division("0.0 cannot be raised to a negative power")
    :math.pow(left, right)
  end

  defp arithmetic(op, left, right), do: unsupported(op, left, right)

  defp numeric?(value), do: is_number(value) or is_boolean(value)

  defp unsupported(op, left, right) do
    symbol =
      %{add: "+", sub: "-", mul: "*", div: "/", floordiv: "//", mod: "%", pow: "** or pow()"}[op]

    raise Otera.Error,
      kind: :type_error,
      message:
        "unsupported operand type(s) for #{symbol}: '#{type_name(left)}' and '#{type_name(right)}'"
  end

  defp zero_division(message),
    do: raise(Otera.Error, kind: :zero_division_error, message: message)

  @doc """
  Applies unary minus or plus.
  """
  @spec unary_op(:neg | :pos, term) :: term
  def unary_op(_op, %Undefined{} = undefined), do: Undefined.fail(undefined)
  def unary_op(:neg, value) when is_number(value) or is_boolean(value), do: -number(value)
  def unary_op(:pos, value) when is_number(value) or is_boolean(value), do: number(value)

  def unary_op(op, value) do
    symbol = if op == :neg, do: "-", else: "+"

    raise Otera.Error,
      kind: :type_error,
      message: "bad operand type for unary #{symbol}: '#{type_name(value)}'"
  end

  ## Containers

  @doc """
  Returns the items of `value` as a list, like Python `iter()`. A dict gives its keys, and a string its characters.
  """
  @spec to_list(term) :: list
  def to_list(%Otera.GroupTuple{grouper: grouper, list: list}), do: [grouper, list]
  def to_list(value) when is_list(value), do: value
  def to_list(value) when is_tuple(value), do: Tuple.to_list(value)
  def to_list(value) when is_binary(value), do: String.codepoints(value)
  def to_list(%Markup{text: text}), do: String.codepoints(text)
  def to_list(%Otera.Range{} = range), do: Otera.Range.to_list(range)
  def to_list(%Dict{} = dict), do: Dict.keys(dict)
  def to_list(%Undefined{}), do: []
  def to_list(%Otera.Bytes{data: data}), do: :binary.bin_to_list(data)
  def to_list(%Iterable{} = iterable), do: Iterable.take_all(iterable)
  def to_list(%Loop{} = loop), do: Loop.remaining(loop)

  def to_list(value),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "'#{type_name(value)}' object is not iterable"
      )

  @doc """
  Returns true if Python can iterate over `value`.
  """
  @spec iterable?(term) :: boolean
  def iterable?(value),
    do:
      is_list(value) or is_tuple(value) or is_binary(value) or is_struct(value, Dict) or
        is_struct(value, Undefined) or is_struct(value, Iterable) or is_struct(value, Loop) or
        is_struct(value, Otera.Bytes) or is_struct(value, Otera.GroupTuple) or
        is_struct(value, Markup) or is_struct(value, Otera.Range)

  @doc """
  Returns the length of `value`, like Python `len()`.
  """
  @spec length(term) :: non_neg_integer
  def length(%Otera.GroupTuple{}), do: 2
  def length(value) when is_binary(value), do: str_length(value)
  def length(%Markup{text: text}), do: str_length(text)
  def length(%Otera.Range{} = range), do: Otera.Range.size(range)
  def length(value) when is_list(value), do: Kernel.length(value)
  def length(value) when is_tuple(value), do: tuple_size(value)
  def length(%Dict{pairs: pairs}), do: Kernel.length(pairs)
  def length(%Undefined{}), do: 0
  def length(%Otera.Bytes{data: data}), do: byte_size(data)

  def length(%Iterable{items: items} = iterable) do
    if Iterable.view?(iterable),
      do: Kernel.length(items),
      else:
        raise(Otera.Error,
          kind: :type_error,
          message: "object of type '#{type_name(iterable)}' has no len()"
        )
  end

  def length(value),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "object of type '#{type_name(value)}' has no len()"
      )

  @doc """
  Returns true if `item in container` in Python.
  """
  @spec contains?(term, term) :: boolean
  def contains?(%Otera.GroupTuple{} = group, item),
    do: contains?(Otera.GroupTuple.to_tuple(group), item)

  def contains?(%Markup{text: text}, item), do: contains?(text, item)
  def contains?(%Otera.Range{} = range, item), do: Otera.Range.member?(range, item)

  def contains?(container, %Markup{text: text}) when is_binary(container),
    do: contains?(container, text)

  def contains?(container, item) when is_binary(container) and is_binary(item),
    do: String.contains?(container, item)

  def contains?(container, item) when is_binary(container),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "'in <string>' requires string as left operand, not #{type_name(item)}"
      )

  def contains?(%Dict{} = dict, item) do
    hashable!(item)
    Enum.any?(Dict.keys(dict), &equal?(&1, item))
  end

  def contains?(%Iterable{} = iterable, item),
    do: Iterable.take_until(iterable, &equal?(&1, item))

  def contains?(container, item)
      when is_list(container) or is_tuple(container) or is_struct(container, Undefined),
      do: Enum.any?(to_list(container), &equal?(&1, item))

  def contains?(container, _item),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "argument of type '#{type_name(container)}' is not iterable"
      )

  ## Lookup

  @doc """
  Looks up `x.name`, like the immutable sandbox of Jinja2: a Python attribute first, then an item.
  """
  @spec getattr(term, String.t()) :: term
  def getattr(%Undefined{} = undefined, _name), do: Undefined.fail(undefined)
  def getattr(%Namespace{} = namespace, name), do: Namespace.get(namespace, name)
  def getattr(%Loop{} = loop, name), do: Loop.get(loop, name)
  def getattr(%Macro{} = macro, name), do: Macro.get(macro, name)
  def getattr(%Otera.TemplateModule{} = module, name), do: Otera.TemplateModule.get(module, name)

  def getattr(%Otera.TemplateReference{context: context} = reference, name) do
    blocks = Otera.State.get({:blocks, context})

    if is_map_key(blocks, name),
      do: %Otera.BlockReference{context: context, name: name, depth: 0},
      else: %Undefined{obj: reference, name: name}
  end

  def getattr(%Otera.BlockReference{} = block, "name"), do: block.name

  def getattr(%Otera.BlockReference{context: context, name: name, depth: depth} = block, "super") do
    if depth + 1 < Kernel.length(Otera.State.get({:blocks, context})[name]),
      do: %{block | depth: depth + 1},
      else: %Undefined{hint: "there is no parent block called #{repr(name)}.", name: "super"}
  end

  def getattr(%Otera.BlockReference{} = block, name), do: %Undefined{obj: block, name: name}
  def getattr(%Otera.Cycler{} = cycler, name), do: Otera.Cycler.get(cycler, name)
  def getattr(%Otera.Joiner{} = joiner, name), do: Otera.Joiner.get(joiner, name)
  def getattr(%Otera.GroupTuple{grouper: grouper}, "grouper"), do: grouper
  def getattr(%Otera.GroupTuple{list: list}, "list"), do: list

  def getattr(%Otera.GroupTuple{} = group, name),
    do: getattr(Otera.GroupTuple.to_tuple(group), name)

  def getattr(number, name)
      when (is_integer(number) or is_boolean(number)) and name in ["real", "numerator"],
      do: number(number)

  def getattr(number, "imag") when is_integer(number) or is_boolean(number), do: 0
  def getattr(number, "denominator") when is_integer(number) or is_boolean(number), do: 1
  def getattr(number, "real") when is_float(number), do: number
  def getattr(number, "imag") when is_float(number), do: 0.0

  def getattr(%Otera.Range{} = range, name) when name in ["start", "stop", "step"],
    do: Map.fetch!(range, String.to_existing_atom(name))

  def getattr(object, name) do
    if Methods.has?(object, name), do: method(object, name), else: item_or_undefined(object, name)
  end

  @doc """
  Raises the Python `TypeError` for a dict key or a set item that is a list or a dict.
  """
  @spec hashable!(term) :: :ok
  def hashable!(value)
      when is_list(value) or is_struct(value, Dict) or is_struct(value, Iterable),
      do: raise(Otera.Error, kind: :type_error, message: "unhashable type: '#{type_name(value)}'")

  def hashable!(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.each(&hashable!/1)

  def hashable!(_value), do: :ok

  @doc """
  Looks up `x[key]`, like the immutable sandbox of Jinja2: an item first, then a Python attribute.
  """
  @spec getitem(term, term) :: term
  def getitem(%Undefined{} = undefined, _key), do: Undefined.fail(undefined)

  def getitem(%Otera.GroupTuple{} = group, key),
    do: getitem(Otera.GroupTuple.to_tuple(group), key)

  def getitem(%Markup{text: text} = markup, index) when is_integer(index) or is_boolean(index) do
    case getitem(text, index) do
      char when is_binary(char) -> Markup.new(char)
      _undefined -> %Undefined{obj: markup, name: index}
    end
  end

  def getitem(object, key) do
    case fetch_item(object, key) do
      {:ok, value} -> value
      :error when is_binary(key) -> getattr(object, key)
      :error -> %Undefined{obj: object, name: key}
    end
  end

  defp item_or_undefined(object, name) do
    case fetch_item(object, name) do
      {:ok, value} -> value
      :error -> %Undefined{obj: object, name: name}
    end
  end

  defp method(object, name) do
    if Methods.safe?(object, name) do
      %Method{receiver: object, name: name}
    else
      %Undefined{
        hint: "access to attribute #{repr(name)} of #{repr(type_name(object))} object is unsafe.",
        obj: object,
        name: name,
        kind: :security_error
      }
    end
  end

  defp fetch_item(%Dict{} = dict, key) do
    case Enum.find(dict.pairs, fn {k, _} -> equal?(k, key) end) do
      {_, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp fetch_item(sequence, index)
       when (is_list(sequence) or is_tuple(sequence) or is_binary(sequence)) and
              (is_integer(index) or is_boolean(index)) do
    items = to_list(sequence)
    index = number(index)
    index = if index < 0, do: Kernel.length(items) + index, else: index
    if index >= 0 and index < Kernel.length(items), do: {:ok, Enum.at(items, index)}, else: :error
  end

  defp fetch_item(%Otera.Range{} = range, index) when is_integer(index) or is_boolean(index),
    do: Otera.Range.fetch(range, number(index))

  defp fetch_item(%Namespace{} = namespace, name) when is_binary(name),
    do: Namespace.fetch(namespace, name)

  defp fetch_item(%Loop{} = loop, name) when is_binary(name), do: {:ok, Loop.get(loop, name)}
  defp fetch_item(_object, _key), do: :error

  @doc """
  Returns `sequence[start:stop:step]` with the Python rules for missing and negative bounds.
  """
  @spec slice(term, term, term, term) :: term
  def slice(%Undefined{} = undefined, _start, _stop, _step), do: Undefined.fail(undefined)

  def slice(%Otera.GroupTuple{} = group, start, stop, step),
    do: slice(Otera.GroupTuple.to_tuple(group), start, stop, step)

  def slice(%Markup{} = markup, start, stop, step),
    do: Markup.map(markup, &slice(&1, start, stop, step))

  def slice(%Otera.Range{} = range, start, stop, step) do
    step = slice_bound(step) || 1

    {start, stop} =
      slice_bounds(Otera.Range.size(range), slice_bound(start), slice_bound(stop), step)

    Otera.Range.slice(range, start, stop, step)
  end

  def slice(sequence, start, stop, step)
      when is_list(sequence) or is_tuple(sequence) or is_binary(sequence) do
    items = to_list(sequence)

    indices =
      slice_indices(
        Kernel.length(items),
        slice_bound(start),
        slice_bound(stop),
        slice_bound(step) || 1
      )

    tuple = List.to_tuple(items)
    picked = Enum.map(indices, &elem(tuple, &1))

    cond do
      is_binary(sequence) -> Enum.join(picked)
      is_tuple(sequence) -> List.to_tuple(picked)
      true -> picked
    end
  end

  def slice(%Dict{}, _start, _stop, _step),
    do: raise(Otera.Error, kind: :type_error, message: "unhashable type: 'slice'")

  def slice(object, _start, _stop, _step), do: %Undefined{obj: object, name: "slice"}

  defp slice_bound(nil), do: nil
  defp slice_bound(bound) when is_integer(bound) or is_boolean(bound), do: number(bound)

  defp slice_bound(_bound),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "slice indices must be integers or None or have an __index__ method"
      )

  defp slice_indices(length, start, stop, step) do
    {start, stop} = slice_bounds(length, start, stop, step)

    cond do
      step > 0 and start < stop -> Enum.to_list(start..(stop - 1)//step)
      step < 0 and start > stop -> Enum.to_list(start..(stop + 1)//step)
      true -> []
    end
  end

  # The start and stop of `slice.indices(length)` in Python.
  defp slice_bounds(_length, _start, _stop, 0),
    do: raise(Otera.Error, kind: :value_error, message: "slice step cannot be zero")

  defp slice_bounds(length, start, stop, step) do
    {lower, upper} = if step > 0, do: {0, length}, else: {-1, length - 1}
    start = adjust_bound(start, length, lower, upper, if(step > 0, do: lower, else: upper))
    stop = adjust_bound(stop, length, lower, upper, if(step > 0, do: upper, else: lower))
    {start, stop}
  end

  defp adjust_bound(nil, _length, _lower, _upper, default), do: default

  defp adjust_bound(bound, length, lower, upper, _default) when bound < 0,
    do: max(bound + length, lower) |> min(upper)

  defp adjust_bound(bound, _length, lower, upper, _default), do: bound |> max(lower) |> min(upper)
end
