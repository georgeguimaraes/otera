defmodule Otera.Filters do
  @moduledoc """
  The builtin filters of Jinja2, with their Python behavior.

  The filters are `abs`, `attr`, `batch`, `capitalize`, `center`, `count`, `default` (`d`), `dictsort`, `escape` (`e`), `filesizeformat`, `first`, `float`, `forceescape`, `format`, `groupby`, `indent`, `int`, `items`, `join`, `last`, `length`, `list`, `lower`, `map`, `max`, `min`, `pprint`, `random`, `reject`, `rejectattr`, `replace`, `reverse`, `round`, `safe`, `select`, `selectattr`, `slice`, `sort`, `string`, `striptags`, `sum`, `title`, `tojson`, `trim`, `truncate`, `unique`, `upper`, `urlencode`, `wordcount`, `wordwrap` and `xmlattr`.

  `safe`, `escape`, `forceescape` and `tojson` give an `Otera.Markup`. As in Jinja2, the string filters keep a `Markup`, and `join`, `replace` and `xmlattr` follow the autoescape of the render. The filters that give a generator in Jinja2, such as `map` and `select`, give an `Otera.Iterable`, which makes a single pass like a Python generator.
  """

  alias Otera.{
    Dict,
    Evaluator,
    HTML,
    Iterable,
    JSON,
    Markup,
    Methods,
    Undefined,
    Value
  }

  @generators ~w(map select reject selectattr rejectattr unique items batch slice)

  @doc """
  Applies the builtin filter `name` to `value`. `env` gives the filters and tests that `map` and `select` call.
  """
  @spec call(String.t(), term, list, Dict.t(), map) :: term
  def call(name, value, args, kwargs, env) do
    result = filter(name, value, args, kwargs, env)
    if name in @generators, do: Iterable.new("generator", result), else: result
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
    Methods.call(Markup.soft_str(value), "strip", [chars], %Dict{})
  end

  defp filter("string", value, args, kwargs, _env) do
    bind("soft_str", args, kwargs, [])
    Markup.soft_str(value)
  end

  defp filter("safe", value, args, kwargs, _env) do
    bind("do_mark_safe", args, kwargs, [])
    Markup.new(Value.to_str(value))
  end

  defp filter(name, value, args, kwargs, _env) when name in ["escape", "e"] do
    bind("escape", args, kwargs, [])
    Markup.escape(value)
  end

  defp filter("forceescape", value, args, kwargs, _env) do
    bind("do_forceescape", args, kwargs, [])
    Markup.escape(Value.to_str(value))
  end

  defp filter("striptags", value, args, kwargs, _env) do
    bind("do_striptags", args, kwargs, [])
    value |> Value.to_str() |> HTML.striptags()
  end

  defp filter("pprint", value, args, kwargs, _env) do
    bind("do_pprint", args, kwargs, [])
    Otera.Pretty.format(value)
  end

  defp filter("wordwrap", value, args, kwargs, _env) do
    params = [
      {"width", 79},
      {"break_long_words", true},
      {"wrapstring", nil},
      {"break_on_hyphens", true}
    ]

    [width, break_long, wrapstring, break_hyphens] = bind("do_wordwrap", args, kwargs, params)
    wrapstring = wrapstring || "\n"

    value
    |> string_method("splitlines", [])
    |> Enum.map_join(Value.to_str(wrapstring), fn line ->
      line
      |> Value.to_str()
      |> Otera.TextWrap.wrap(width, Value.truthy?(break_long), Value.truthy?(break_hyphens))
      |> Enum.join(wrapstring)
    end)
  end

  defp filter("urlencode", value, args, kwargs, _env) do
    bind("do_urlencode", args, kwargs, [])

    if is_binary(value) or is_struct(value, Markup) or not Value.iterable?(value) do
      url_quote(value, false)
    else
      value
      |> url_items()
      |> Enum.map_join("&", fn pair ->
        [key, item] = Value.to_list(pair)
        url_quote(key, true) <> "=" <> url_quote(item, true)
      end)
    end
  end

  defp filter("xmlattr", value, args, kwargs, env) do
    [autospace] = bind("do_xmlattr", args, kwargs, [{"autospace", true}])

    text =
      value
      |> dict_items()
      |> Enum.reject(fn {_key, item} -> item == nil or is_struct(item, Undefined) end)
      |> Enum.map_join(" ", fn {key, item} ->
        if Regex.match?(~r/[ \t\n\r\f\v\/>=]/, key) do
          raise Otera.Error,
            kind: :value_error,
            message: "Invalid character in attribute name: #{Value.repr(key)}"
        end

        "#{Markup.escape(key).text}=\"#{Markup.escape(item).text}\""
      end)

    text = if Value.truthy?(autospace) and text != "", do: " " <> text, else: text
    if Evaluator.autoescape?(env), do: Markup.new(text), else: text
  end

  defp filter("filesizeformat", value, args, kwargs, _env) do
    [binary] = bind("do_filesizeformat", args, kwargs, [{"binary", false}])
    file_size(python_float(value), Value.truthy?(binary))
  end

  defp filter("random", value, args, kwargs, _env) do
    bind("do_random", args, kwargs, [])

    case Value.to_list(value) do
      [] -> %Undefined{hint: "No random item, sequence was empty."}
      items -> Enum.random(items)
    end
  end

  defp filter("groupby", value, args, kwargs, _env) do
    params = ["attribute", {"default", nil}, {"case_sensitive", false}]
    [attribute, default, case_sensitive] = bind("do_groupby", args, kwargs, params)
    getter = attrgetter(attribute, default)
    key = &postprocess(getter.(&1), case_sensitive)

    value
    |> Value.to_list()
    |> sort_by(key, false)
    |> Enum.chunk_while(
      [],
      fn item, chunk ->
        if chunk == [] or Value.equal?(key.(hd(chunk)), key.(item)),
          do: {:cont, [item | chunk]},
          else: {:cont, Enum.reverse(chunk), [item]}
      end,
      &if(&1 == [], do: {:cont, []}, else: {:cont, Enum.reverse(&1), []})
    )
    |> Enum.map(fn [first | _] = items ->
      %Otera.GroupTuple{
        grouper: if(Value.truthy?(case_sensitive), do: key.(first), else: getter.(first)),
        list: items
      }
    end)
  end

  defp filter(name, value, args, kwargs, _env) when name in ["upper", "lower", "capitalize"] do
    bind("do_#{name}", args, kwargs, [])
    Methods.call(Markup.soft_str(value), name, [], %Dict{})
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

  defp filter("replace", value, args, kwargs, env) do
    [old, new, count] = bind("do_replace", args, kwargs, ["old", "new", {"count", nil}])

    # Like do_replace: with autoescape, a Markup argument escapes a plain string value.
    value =
      cond do
        not Evaluator.autoescape?(env) ->
          Value.to_str(value)

        is_struct(old, Markup) or (is_struct(new, Markup) and not is_struct(value, Markup)) ->
          Markup.escape(value)

        true ->
          Markup.soft_str(value)
      end

    plain = &if(Evaluator.autoescape?(env), do: Markup.soft_str(&1), else: Value.to_str(&1))
    Methods.call(value, "replace", [plain.(old), plain.(new), count || -1], %Dict{})
  end

  defp filter("center", value, args, kwargs, _env) do
    [width] = bind("do_center", args, kwargs, [{"width", 80}])
    Methods.call(Markup.soft_str(value), "center", [width], %Dict{})
  end

  defp filter("indent", value, args, kwargs, _env) do
    [width, first, blank] =
      bind("do_indent", args, kwargs, [{"width", 4}, {"first", false}, {"blank", false}])

    indention =
      if is_binary(width) or is_struct(width, Markup),
        do: Value.to_str(width),
        else: Value.to_str(Value.binary_op(:mul, " ", width))

    # A Markup value makes the indention a Markup too, so nothing is escaped.
    Markup.map(indent_value(value), &indent(&1, indention, first, blank))
  end

  defp filter("truncate", value, args, kwargs, _env) do
    [length, killwords, ending, leeway] =
      bind("do_truncate", args, kwargs, [
        {"length", 255},
        {"killwords", false},
        {"end", "..."},
        {"leeway", nil}
      ])

    string = Markup.soft_str(value)
    leeway = leeway || 5

    cond do
      Value.length(string) <= length + leeway ->
        string

      Value.truthy?(killwords) ->
        string
        |> Value.slice(0, length - Value.str_length(ending), nil)
        |> then(&Value.binary_op(:add, &1, ending))

      true ->
        string
        |> Value.slice(0, length - Value.str_length(ending), nil)
        |> Methods.call("rsplit", [" ", 1], %Dict{})
        |> hd()
        |> then(&Value.binary_op(:add, &1, ending))
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

    Value.binary_op(
      :mod,
      Markup.soft_str(value),
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

    # Like next(iter(value)), which takes one item of an iterator.
    first =
      case value do
        %Iterable{} ->
          Iterable.next(value)

        value ->
          value
          |> Value.to_list()
          |> Enum.take(1)
          |> then(&if(&1 == [], do: :error, else: {:ok, hd(&1)}))
      end

    case first do
      {:ok, first} -> first
      :error -> %Undefined{hint: "No first item, sequence was empty."}
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
          items when is_struct(value, Markup) -> Markup.new(List.last(items))
          items -> List.last(items)
        end
    end
  end

  defp filter("reverse", value, args, kwargs, _env) do
    bind("do_reverse", args, kwargs, [])

    case value do
      value when is_binary(value) or is_struct(value, Markup) ->
        Value.slice(value, nil, nil, -1)

      %Iterable{type: "generator"} ->
        value |> Value.to_list() |> Enum.reverse()

      value ->
        unless Value.iterable?(value), do: filter_argument_error("argument must be iterable")
        Iterable.new(reverse_type(value), value |> Value.to_list() |> Enum.reverse())
    end
  end

  defp filter("join", value, args, kwargs, env) do
    [separator, attribute] = bind("do_join", args, kwargs, [{"d", ""}, {"attribute", nil}])
    getter = attrgetter(attribute)
    items = value |> Value.to_list() |> Enum.map(getter)

    # Like do_join: with autoescape, a Markup item or separator escapes the plain strings.
    if Evaluator.autoescape?(env) and
         (is_struct(separator, Markup) or Enum.any?(items, &is_struct(&1, Markup))),
       do: Methods.call(Markup.escape(separator), "join", [items], %Dict{}),
       else: Enum.map_join(items, Value.to_str(separator), &Value.to_str/1)
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

    case Value.attribute(value, Value.to_str(name)) do
      {:ok, attribute} -> attribute
      :error -> %Undefined{obj: value, name: name}
    end
  end

  defp filter("batch", value, args, kwargs, _env) do
    [count, fill_with] = bind("do_batch", args, kwargs, ["linecount", {"fill_with", nil}])
    batch(Value.to_list(value), count, fill_with, [], [])
  end

  defp filter("slice", value, args, kwargs, _env) do
    [slices, fill_with] = bind("do_slice", args, kwargs, ["slices", {"fill_with", nil}])
    items = Value.to_list(value)
    per_slice = Value.binary_op(:floordiv, length(items), slices)
    with_extra = Value.binary_op(:mod, length(items), slices)

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
    |> Markup.new()
  end

  defp filter(name, _value, _args, _kwargs, _env),
    do:
      raise(Otera.Error,
        kind: :template_runtime_error,
        message: "No filter named #{Value.repr(name)}."
      )

  @doc """
  Returns true if `name` is a builtin filter.
  """
  @spec builtin?(String.t()) :: boolean
  def builtin?(name) do
    name in ~w(abs attr batch capitalize center count d default dictsort e escape filesizeformat first float forceescape format groupby indent int items join last length list lower map max min pprint random reject rejectattr replace reverse round safe select selectattr slice sort string striptags sum title tojson trim truncate unique upper urlencode wordcount wordwrap xmlattr)
  end

  defp string_method(%Undefined{} = undefined, _name, _args), do: Undefined.fail(undefined)

  defp string_method(value, name, args) when is_binary(value) or is_struct(value, Markup),
    do: Methods.call(value, name, args, %Dict{})

  defp string_method(value, name, _args),
    do:
      raise(Otera.Error,
        kind: :attribute_error,
        message: "'#{Value.type_name(value)}' object has no attribute '#{name}'"
      )

  defp url_items(%Dict{pairs: pairs}), do: pairs
  defp url_items(value), do: Value.to_list(value)

  # Python urllib.parse.quote: letters, digits, "_.-~" and the safe "/" stay, other bytes become %XX.
  defp url_quote(value, query?) do
    text = for <<byte <- Value.to_str(value)>>, into: "", do: quote_byte(byte, query?)
    if query?, do: String.replace(text, "%20", "+"), else: text
  end

  defp quote_byte(byte, query?) do
    if byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in ~c"_.-~" or
         (byte == ?/ and not query?),
       do: <<byte>>,
       else: "%" <> String.pad_leading(Integer.to_string(byte, 16), 2, "0")
  end

  defp file_size(1.0, _binary), do: "1 Byte"

  defp file_size(bytes, binary) do
    base = if binary, do: 1024, else: 1000

    prefixes =
      if binary, do: ~w(KiB MiB GiB TiB PiB EiB ZiB YiB), else: ~w(kB MB GB TB PB EB ZB YB)

    if bytes < base do
      "#{trunc(bytes)} Bytes"
    else
      units =
        for {prefix, power} <- Enum.with_index(prefixes, 2),
            do: {prefix, Integer.pow(base, power)}

      {prefix, unit} = Enum.find(units, List.last(units), fn {_, unit} -> bytes < unit end)

      size = base * bytes / unit
      sign = if size < 0, do: "-", else: ""
      "#{sign}#{Otera.Format.fixed(abs(size), 1)} #{prefix}"
    end
  end

  # Python float(value), with its errors.
  defp python_float(value) do
    case to_float(value) do
      nil when is_binary(value) or is_struct(value, Markup) ->
        raise Otera.Error,
          kind: :value_error,
          message: "could not convert string to float: #{Value.repr(value)}"

      nil ->
        raise Otera.Error,
          kind: :type_error,
          message:
            "float() argument must be a string or a real number, not '#{Value.type_name(value)}'"

      float ->
        float
    end
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

  # do_batch of Jinja2: a batch goes out when the next item comes, so a count of 0 gives an empty batch.
  defp batch([], _count, _fill_with, [], batches), do: Enum.reverse(batches)

  defp batch([], count, fill_with, tmp, batches) do
    tmp = Enum.reverse(tmp)

    tmp =
      if fill_with != nil and length(tmp) < count,
        do: tmp ++ List.duplicate(fill_with, count - length(tmp)),
        else: tmp

    Enum.reverse([tmp | batches])
  end

  defp batch([item | rest], count, fill_with, tmp, batches) do
    if length(tmp) == count,
      do: batch(rest, count, fill_with, [item], [Enum.reverse(tmp) | batches]),
      else: batch(rest, count, fill_with, [item | tmp], batches)
  end

  defp filter_argument_error(message),
    do: raise(Otera.Error, kind: :filter_argument_error, message: message)

  defp indent(text, indention, first, blank) do
    lines = Methods.call(text, "splitlines", [], %Dict{})

    text =
      if Value.truthy?(blank) do
        Enum.join(lines, "\n" <> indention)
      else
        [head | tail] = lines
        tail = Enum.map(tail, fn line -> if line == "", do: line, else: indention <> line end)
        Enum.join([head | tail], "\n")
      end

    if Value.truthy?(first), do: indention <> text, else: text
  end

  # Jinja2 runs `s += "\n"` on the value of indent.
  defp indent_value(value) when is_binary(value) or is_struct(value, Markup),
    do: Markup.map(value, &(&1 <> "\n"))

  defp indent_value(%Undefined{} = undefined), do: Undefined.fail(undefined)

  defp indent_value(value),
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
  defp reverse_type(%Otera.Range{}), do: "range_iterator"
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
    if (is_binary(value) or is_struct(value, Markup)) and not Value.truthy?(case_sensitive),
      do: String.downcase(Value.to_str(value)),
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

  defp to_int(%Markup{text: text}, base), do: to_int(text, base)

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

  defp to_float(%Markup{text: text}), do: to_float(text)

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
