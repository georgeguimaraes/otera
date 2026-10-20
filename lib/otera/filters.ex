defmodule Otera.Filters do
  @moduledoc """
  The builtin filters of Jinja2, with their Python behavior.

  The filters are `abs`, `attr`, `batch`, `capitalize`, `center`, `count`, `default` (`d`), `dictsort`, `escape` (`e`), `first`, `float`, `format`, `indent`, `int`, `items`, `join`, `last`, `length`, `list`, `lower`, `map`, `max`, `min`, `reject`, `rejectattr`, `replace`, `reverse`, `round`, `safe`, `select`, `selectattr`, `slice`, `sort`, `string`, `sum`, `title`, `tojson`, `trim`, `truncate`, `unique`, `upper` and `wordcount`.

  Without autoescape, `safe` only converts its value to a string. `escape` always escapes HTML, as in Jinja2. The filters that give a generator in Jinja2, such as `map` and `select`, give a list.
  """

  alias Otera.{Dict, Evaluator, Iterable, JSON, Loop, Macro, Methods, Namespace, Undefined, Value}

  @generators ~w(map select reject selectattr rejectattr unique items batch slice)

  @doc """
  Applies the builtin filter `name` to `value`. `env` gives the filters and tests that `map` and `select` call.
  """
  @spec call(String.t(), term, list, Dict.t(), map) :: term
  def call(name, value, args, kwargs, env) do
    result = filter(name, value, args, kwargs, env)
    if name in @generators, do: %Iterable{type: "generator", items: result}, else: result
  end

  defp filter(name, value, args, kwargs, _env) when name in ["length", "count"] do
    bind(name, args, kwargs, [])
    Value.length(value)
  end

  defp filter("default", value, args, kwargs, env), do: call("d", value, args, kwargs, env)

  defp filter("d", value, args, kwargs, _env) do
    [default, boolean] =
      bind("do_default", args, kwargs, [{"default_value", ""}, {"boolean", false}])

    if is_struct(value, Undefined) or (Value.truthy?(boolean) and not Value.truthy?(value)),
      do: default,
      else: value
  end

  defp filter("trim", value, args, kwargs, _env) do
    [chars] = bind("do_trim", args, kwargs, [{"chars", nil}])
    Methods.call(Value.to_str(value), "strip", [chars], %Dict{})
  end

  defp filter("string", value, args, kwargs, _env) do
    bind("soft_str", args, kwargs, [])
    Value.to_str(value)
  end

  defp filter("safe", value, args, kwargs, _env) do
    bind("do_mark_safe", args, kwargs, [])
    Value.to_str(value)
  end

  defp filter(name, value, args, kwargs, _env) when name in ["escape", "e"] do
    bind("escape", args, kwargs, [])

    value
    |> Value.to_str()
    |> String.replace(["&", "<", ">", "'", "\""], fn
      "&" -> "&amp;"
      "<" -> "&lt;"
      ">" -> "&gt;"
      "'" -> "&#39;"
      "\"" -> "&#34;"
    end)
  end

  defp filter(name, value, args, kwargs, _env) when name in ["upper", "lower", "capitalize"] do
    bind("do_#{name}", args, kwargs, [])
    Methods.call(Value.to_str(value), name, [], %Dict{})
  end

  defp filter("title", value, args, kwargs, _env) do
    bind("do_title", args, kwargs, [])

    ~r/([-\s({\[<]+)/u
    |> Regex.split(Value.to_str(value), include_captures: true)
    |> Enum.map_join(fn
      "" ->
        ""

      <<first::utf8, rest::binary>> ->
        String.upcase(<<first::utf8>>) <> Methods.call(rest, "lower", [], %Dict{})
    end)
  end

  defp filter("replace", value, args, kwargs, _env) do
    [old, new, count] = bind("do_replace", args, kwargs, ["old", "new", {"count", nil}])

    Methods.call(
      Value.to_str(value),
      "replace",
      [Value.to_str(old), Value.to_str(new), count || -1],
      %Dict{}
    )
  end

  defp filter("center", value, args, kwargs, _env) do
    [width] = bind("do_center", args, kwargs, [{"width", 80}])
    Methods.call(Value.to_str(value), "center", [width], %Dict{})
  end

  defp filter("indent", value, args, kwargs, _env) do
    [width, first, blank] =
      bind("do_indent", args, kwargs, [{"width", 4}, {"first", false}, {"blank", false}])

    indention = if is_binary(width), do: width, else: String.duplicate(" ", width)
    lines = Methods.call(indent_text(value), "splitlines", [], %Dict{})

    text =
      if Value.truthy?(blank) do
        Enum.join(lines, "\n" <> indention)
      else
        [head | tail] = lines

        Enum.join(
          [
            head | Enum.map(tail, fn line -> if line == "", do: line, else: indention <> line end)
          ],
          "\n"
        )
      end

    if Value.truthy?(first), do: indention <> text, else: text
  end

  defp filter("truncate", value, args, kwargs, _env) do
    [length, killwords, ending, leeway] =
      bind("do_truncate", args, kwargs, [
        {"length", 255},
        {"killwords", false},
        {"end", "..."},
        {"leeway", nil}
      ])

    string = Value.to_str(value)
    leeway = leeway || 5

    cond do
      Value.str_length(string) <= length + leeway ->
        string

      Value.truthy?(killwords) ->
        Value.slice(string, 0, length - Value.str_length(ending), nil) <> ending

      true ->
        string
        |> Value.slice(0, length - Value.str_length(ending), nil)
        |> Methods.call("rsplit", [" ", 1], %Dict{})
        |> hd()
        |> Kernel.<>(ending)
    end
  end

  defp filter("wordcount", value, args, kwargs, _env) do
    bind("do_wordcount", args, kwargs, [])
    ~r/[\p{L}\p{N}_]+/u |> Regex.scan(Value.to_str(value)) |> length()
  end

  defp filter("format", value, args, kwargs, _env) do
    if args != [] and kwargs.pairs != [],
      do:
        raise(Otera.Error,
          kind: :filter_argument_error,
          message: "can't handle positional and keyword arguments at the same time"
        )

    Otera.Format.printf(
      Value.to_str(value),
      if(kwargs.pairs != [], do: kwargs, else: List.to_tuple(args))
    )
  end

  defp filter("int", value, args, kwargs, _env) do
    [default, base] = bind("do_int", args, kwargs, [{"default", 0}, {"base", 10}])
    to_int(value, base) || default
  end

  defp filter("float", value, args, kwargs, _env) do
    [default] = bind("do_float", args, kwargs, [{"default", 0.0}])
    to_float(value) || default
  end

  defp filter("abs", value, args, kwargs, _env) do
    bind("abs", args, kwargs, [])

    case value do
      value when is_number(value) ->
        abs(value)

      value when is_boolean(value) ->
        if(value, do: 1, else: 0)

      value ->
        raise Otera.Error,
          kind: :type_error,
          message: "bad operand type for abs(): '#{Value.type_name(value)}'"
    end
  end

  defp filter("round", value, args, kwargs, _env) do
    [precision, method] = bind("do_round", args, kwargs, [{"precision", 0}, {"method", "common"}])
    round_number(value, precision, method)
  end

  defp filter("list", value, args, kwargs, _env) do
    bind("do_list", args, kwargs, [])
    Value.to_list(value)
  end

  defp filter("items", value, args, kwargs, _env) do
    bind("do_items", args, kwargs, [])

    case value do
      %Undefined{} ->
        []

      %Dict{pairs: pairs} ->
        pairs

      _ ->
        raise Otera.Error, kind: :type_error, message: "Can only get item pairs from a mapping."
    end
  end

  defp filter("first", value, args, kwargs, _env) do
    bind("do_first", args, kwargs, [])

    case Value.to_list(value) do
      [first | _] -> first
      [] -> %Undefined{hint: "No first item, sequence was empty."}
    end
  end

  defp filter("last", value, args, kwargs, _env) do
    bind("do_last", args, kwargs, [])

    case value do
      %Iterable{type: type} when type not in ["dict_keys", "dict_values", "dict_items"] ->
        raise Otera.Error, kind: :type_error, message: "'#{type}' object is not reversible"

      value ->
        case Value.to_list(value) do
          [] -> %Undefined{hint: "No last item, sequence was empty."}
          items -> List.last(items)
        end
    end
  end

  defp filter("reverse", value, args, kwargs, _env) do
    bind("do_reverse", args, kwargs, [])

    case value do
      value when is_binary(value) ->
        Value.slice(value, nil, nil, -1)

      %Iterable{type: "generator"} ->
        value |> Value.to_list() |> Enum.reverse()

      value ->
        unless Value.iterable?(value), do: filter_argument_error("argument must be iterable")
        %Iterable{type: reverse_type(value), items: value |> Value.to_list() |> Enum.reverse()}
    end
  end

  defp filter("join", value, args, kwargs, _env) do
    [separator, attribute] = bind("do_join", args, kwargs, [{"d", ""}, {"attribute", nil}])
    getter = attrgetter(attribute)
    value |> Value.to_list() |> Enum.map_join(Value.to_str(separator), &Value.to_str(getter.(&1)))
  end

  defp filter("sum", value, args, kwargs, _env) do
    [attribute, start] = bind("do_sum", args, kwargs, [{"attribute", nil}, {"start", 0}])
    getter = attrgetter(attribute)
    value |> Value.to_list() |> Enum.reduce(start, &Value.binary_op(:add, &2, getter.(&1)))
  end

  defp filter("dictsort", value, args, kwargs, _env) do
    [case_sensitive, by, reverse] =
      bind("do_dictsort", args, kwargs, [
        {"case_sensitive", false},
        {"by", "key"},
        {"reverse", false}
      ])

    position =
      case by do
        "key" ->
          0

        "value" ->
          1

        _ ->
          raise Otera.Error,
            kind: :filter_argument_error,
            message: ~s(You can only sort by either "key" or "value")
      end

    value
    |> dict_items()
    |> sort_by(&postprocess(elem(&1, position), case_sensitive), Value.truthy?(reverse))
  end

  defp filter("sort", value, args, kwargs, _env) do
    [reverse, case_sensitive, attribute] =
      bind("do_sort", args, kwargs, [
        {"reverse", false},
        {"case_sensitive", false},
        {"attribute", nil}
      ])

    getters =
      if is_binary(attribute),
        do: attribute |> String.split(",") |> Enum.map(&attrgetter/1),
        else: [attrgetter(attribute)]

    value
    |> Value.to_list()
    |> sort_by(
      fn item -> Enum.map(getters, &postprocess(&1.(item), case_sensitive)) end,
      Value.truthy?(reverse)
    )
  end

  defp filter("unique", value, args, kwargs, _env) do
    [case_sensitive, attribute] =
      bind("do_unique", args, kwargs, [{"case_sensitive", false}, {"attribute", nil}])

    getter = attrgetter(attribute)

    {items, _seen} =
      value
      |> Value.to_list()
      |> Enum.reduce({[], []}, fn item, {items, seen} ->
        key = postprocess(getter.(item), case_sensitive)
        Value.hashable!(key)

        if Enum.any?(seen, &Value.equal?(&1, key)),
          do: {items, seen},
          else: {[item | items], [key | seen]}
      end)

    Enum.reverse(items)
  end

  defp filter(name, value, args, kwargs, _env) when name in ["min", "max"] do
    [case_sensitive, attribute] =
      bind("do_#{name}", args, kwargs, [{"case_sensitive", false}, {"attribute", nil}])

    getter = attrgetter(attribute)
    wanted = if name == "min", do: :lt, else: :gt

    case Value.to_list(value) do
      [] ->
        %Undefined{hint: "No aggregated item, sequence was empty."}

      [first | rest] ->
        key = &postprocess(getter.(&1), case_sensitive)
        Enum.reduce(rest, first, &if(Value.compare(wanted, key.(&1), key.(&2)), do: &1, else: &2))
    end
  end

  defp filter("map", value, args, kwargs, env) do
    if Value.truthy?(value),
      do: value |> Value.to_list() |> Enum.map(map_function(args, kwargs, env)),
      else: []
  end

  defp filter(name, value, args, kwargs, env)
       when name in ["select", "reject", "selectattr", "rejectattr"] do
    if Value.truthy?(value) do
      {getter, args} =
        if name in ["selectattr", "rejectattr"], do: select_attribute(args), else: {& &1, args}

      test = select_test(args, kwargs, env)
      keep = name in ["select", "selectattr"]
      value |> Value.to_list() |> Enum.filter(&(test.(getter.(&1)) == keep))
    else
      []
    end
  end

  defp filter("attr", value, args, kwargs, _env) do
    [name] = bind("do_attr", args, kwargs, ["name"])

    if Methods.has?(value, name) or is_struct(value, Namespace) or is_struct(value, Loop) or
         is_struct(value, Macro),
       do: Value.getattr(value, name),
       else: %Undefined{obj: value, name: name}
  end

  defp filter("batch", value, args, kwargs, _env) do
    [count, fill_with] = bind("do_batch", args, kwargs, ["linecount", {"fill_with", nil}])

    value
    |> Value.to_list()
    |> Enum.chunk_every(count)
    |> Enum.map(fn chunk ->
      if fill_with != nil and length(chunk) < count,
        do: chunk ++ List.duplicate(fill_with, count - length(chunk)),
        else: chunk
    end)
  end

  defp filter("slice", value, args, kwargs, _env) do
    [slices, fill_with] = bind("do_slice", args, kwargs, ["slices", {"fill_with", nil}])
    items = Value.to_list(value)
    per_slice = div(length(items), slices)
    with_extra = rem(length(items), slices)

    Enum.map(0..(slices - 1)//1, fn number ->
      start = number * per_slice + min(number, with_extra)
      size = per_slice + if(number < with_extra, do: 1, else: 0)
      chunk = Enum.slice(items, start, size)
      if fill_with != nil and number >= with_extra, do: chunk ++ [fill_with], else: chunk
    end)
  end

  defp filter("tojson", value, args, kwargs, _env) do
    [indent] = bind("do_tojson", args, kwargs, [{"indent", nil}])

    value
    |> JSON.dumps(sort_keys: true, indent: indent)
    |> String.replace(["<", ">", "&", "'"], fn
      "<" -> "\\u003c"
      ">" -> "\\u003e"
      "&" -> "\\u0026"
      "'" -> "\\u0027"
    end)
  end

  defp filter(name, _value, _args, _kwargs, _env),
    do:
      raise(Otera.Error,
        kind: :template_runtime_error,
        message: "No filter named #{Value.repr(name)} found."
      )

  @doc """
  Returns true if `name` is a builtin filter.
  """
  @spec builtin?(String.t()) :: boolean
  def builtin?(name) do
    name in ~w(abs attr batch capitalize center count d default dictsort e escape first float format indent int items join last length list lower map max min reject rejectattr replace reverse round safe select selectattr slice sort string sum title tojson trim truncate unique upper wordcount)
  end

  defp map_function([name | rest], kwargs, env),
    do: &Evaluator.call_filter(env, name, &1, rest, kwargs)

  defp map_function([], kwargs, _env) do
    unexpected = Enum.find(kwargs.pairs, fn {key, _} -> key not in ["attribute", "default"] end)

    case {Dict.fetch(kwargs, "attribute"), unexpected} do
      {:error, _} -> filter_argument_error("map requires a filter argument")
      {{:ok, attribute}, nil} -> attrgetter(attribute, kwargs["default"])
      {_, {key, _}} -> filter_argument_error("Unexpected keyword argument #{Value.repr(key)}")
    end
  end

  defp select_attribute([attribute | rest]), do: {attrgetter(attribute), rest}
  defp select_attribute([]), do: filter_argument_error("Missing parameter for attribute name")

  defp select_test([test | rest], kwargs, env),
    do: &Evaluator.call_test(env, test, &1, rest, kwargs)

  defp select_test([], _kwargs, _env), do: &Value.truthy?/1

  defp filter_argument_error(message),
    do: raise(Otera.Error, kind: :filter_argument_error, message: message)

  # Jinja2 runs `s += "\n"` on the value of indent.
  defp indent_text(value) when is_binary(value), do: value <> "\n"
  defp indent_text(%Undefined{} = undefined), do: Undefined.fail(undefined)

  defp indent_text(value),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "unsupported operand type(s) for +=: '#{Value.type_name(value)}' and 'str'"
      )

  defp reverse_type(value) when is_list(value), do: "list_reverseiterator"
  defp reverse_type(%Dict{}), do: "dict_reversekeyiterator"
  defp reverse_type(%Iterable{type: "dict_keys"}), do: "dict_reversekeyiterator"
  defp reverse_type(%Iterable{type: "dict_values"}), do: "dict_reversevalueiterator"
  defp reverse_type(%Iterable{type: "dict_items"}), do: "dict_reverseitemiterator"
  defp reverse_type(_value), do: "reversed"

  # The Python filters take the value as their first argument.
  defp bind(function, args, kwargs, params) do
    [_value | values] = Methods.bind([nil | args], kwargs, ["value" | params], function)
    values
  end

  # dictsort calls value.items() in Python.
  defp dict_items(%Dict{pairs: pairs}), do: pairs
  defp dict_items(%Undefined{} = undefined), do: Undefined.fail(undefined)

  defp dict_items(value),
    do:
      raise(Otera.Error,
        kind: :attribute_error,
        message: "'#{Value.type_name(value)}' object has no attribute 'items'"
      )

  # Looks up a dotted attribute path such as "function.name" with item lookup first, like Jinja2.
  defp attrgetter(attribute, default \\ nil)
  defp attrgetter(nil, _default), do: & &1

  defp attrgetter(attribute, default) do
    parts =
      if is_binary(attribute),
        do:
          attribute
          |> String.split(".")
          |> Enum.map(&if(&1 =~ ~r/\A\d+\z/, do: String.to_integer(&1), else: &1)),
        else: [attribute]

    fn item -> Enum.reduce(parts, item, &lookup_part(&2, &1, default)) end
  end

  defp lookup_part(item, part, default) do
    case Value.getitem(item, part) do
      %Undefined{} when default != nil -> default
      value -> value
    end
  end

  defp postprocess(value, case_sensitive) do
    if is_binary(value) and not Value.truthy?(case_sensitive),
      do: String.downcase(value),
      else: value
  end

  # A stable sort by key with the Python ordering, like `sorted(items, key=key, reverse=reverse)`.
  defp sort_by(items, key, reverse) do
    items
    |> Enum.map(&{key.(&1), &1})
    |> Enum.sort(fn {left, _}, {right, _} ->
      if reverse,
        do: not Value.compare(:lt, left, right),
        else: not Value.compare(:lt, right, left)
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp to_int(%Undefined{} = undefined, _base), do: Undefined.fail(undefined)
  defp to_int(value, _base) when is_integer(value), do: value
  defp to_int(value, _base) when is_boolean(value), do: if(value, do: 1, else: 0)
  defp to_int(value, _base) when is_float(value), do: trunc(value)

  defp to_int(value, base) when is_binary(value) do
    with nil <- parse_int(Value.strip(value, nil, :both), base),
         float when is_float(float) <- to_float(value) do
      trunc(float)
    end
  end

  defp to_int(_value, _base), do: nil

  # Python `int(text, base)`: a sign, digits with single underscores, and a prefix for bases 0, 2, 8 and 16.
  defp parse_int(text, base) when base == 0 or base in 2..36 do
    {sign, text} = split_sign(text)
    {base, digits} = int_base(base, String.downcase(String.slice(text, 0, 2)), text)

    with true <- base != :invalid and digits =~ ~r/\A[0-9a-zA-Z]+(_[0-9a-zA-Z]+)*\z/,
         {integer, ""} <- Integer.parse(String.replace(digits, "_", ""), base) do
      sign * integer
    else
      _ -> nil
    end
  end

  defp parse_int(_text, _base), do: nil

  defp split_sign("-" <> text), do: {-1, text}
  defp split_sign("+" <> text), do: {1, text}
  defp split_sign(text), do: {1, text}

  defp int_base(base, "0x", text) when base in [0, 16], do: {16, String.slice(text, 2..-1//1)}
  defp int_base(base, "0o", text) when base in [0, 8], do: {8, String.slice(text, 2..-1//1)}
  defp int_base(base, "0b", text) when base in [0, 2], do: {2, String.slice(text, 2..-1//1)}
  defp int_base(0, _prefix, text), do: {if(text =~ ~r/\A0+[1-9]/, do: :invalid, else: 10), text}
  defp int_base(base, _prefix, text), do: {base, text}

  defp to_float(%Undefined{} = undefined), do: Undefined.fail(undefined)
  defp to_float(value) when is_float(value), do: value

  defp to_float(value) when is_integer(value) do
    value * 1.0
  rescue
    ArithmeticError ->
      reraise Otera.Error,
              [kind: :overflow_error, message: "int too large to convert to float"],
              __STACKTRACE__
  end

  defp to_float(value) when is_boolean(value), do: if(value, do: 1.0, else: 0.0)

  defp to_float(value) when is_binary(value) do
    text = value |> Value.strip(nil, :both) |> String.replace("_", "") |> String.downcase()

    text =
      cond do
        text =~ ~r/\A[+-]?\./ -> String.replace(text, ".", "0.", global: false)
        text =~ ~r/\A[+-]?\d+\.(e|$)/ -> String.replace(text, ".", ".0", global: false)
        true -> text
      end

    cond do
      text =~ ~r/\A[+-]?(inf|infinity|nan)\z/ -> unsupported_float()
      match?({_, ""}, Float.parse(text)) -> text |> Float.parse() |> elem(0)
      text =~ ~r/\A[+-]?\d+(\.\d*)?(e[+-]?\d+)?\z/ -> unsupported_float()
      true -> nil
    end
  end

  defp to_float(_value), do: nil

  defp unsupported_float,
    do:
      raise(Otera.Error,
        kind: :not_implemented_error,
        message: "Otera does not support the floats inf and nan"
      )

  defp round_number(_value, _precision, method) when method not in ["common", "ceil", "floor"],
    do: filter_argument_error("method must be common, ceil or floor")

  defp round_number(value, precision, method) when is_boolean(value),
    do: round_number(if(value, do: 1, else: 0), precision, method)

  defp round_number(value, precision, "common") when is_integer(value) and precision >= 0,
    do: value

  # Python rounds an integer to tens, hundreds and so on with ties to even.
  defp round_number(value, precision, "common") when is_integer(value) do
    unit = Integer.pow(10, -precision)
    remainder = Integer.mod(value, unit)
    base = value - remainder

    cond do
      2 * remainder > unit -> base + unit
      2 * remainder < unit or rem(div(base, unit), 2) == 0 -> base
      true -> base + unit
    end
  end

  defp round_number(value, precision, "common") when is_float(value) do
    sign = if value < 0 or <<value::float>> == <<-0.0::float>>, do: "-", else: ""
    {rounded, ""} = Float.parse(sign <> Otera.Format.fixed(abs(value), precision))
    rounded
  end

  # Like Python: math.ceil(value * 10 ** precision) / 10 ** precision, where math.ceil gives an integer.
  defp round_number(value, precision, method) when method in ["ceil", "floor"] do
    scale = if precision >= 0, do: Integer.pow(10, precision), else: :math.pow(10, precision)

    case Value.binary_op(:mul, value, scale) do
      scaled when is_number(scaled) ->
        rounded =
          if method == "ceil", do: Float.ceil(scaled * 1.0), else: Float.floor(scaled * 1.0)

        Value.binary_op(:div, trunc(rounded), scale)

      scaled ->
        raise Otera.Error,
          kind: :type_error,
          message: "must be real number, not #{Value.type_name(scaled)}"
    end
  end

  defp round_number(value, _precision, _method),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "type #{Value.type_name(value)} doesn't define __round__ method"
      )
end
