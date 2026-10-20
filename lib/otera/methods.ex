defmodule Otera.Methods do
  @moduledoc """
  The Python methods that templates call on values, such as `content.strip()`, `name.startswith("get_")` or `message.get("tool_calls")`.

  `has?/2` knows every method of the Python types `str`, `list`, `tuple`, `dict`, `int` and `float`, because a method name hides a dict key of the same name in `x.name`. `call/4` runs the methods that chat templates use. As in the immutable sandbox of transformers, the methods that change a list or a dict are unsafe.
  """

  alias Otera.{Dict, Format, HTML, Iterable, Loop, Markup, Unicode, Value}

  @str ~w(capitalize casefold center count encode endswith expandtabs find format format_map index isalnum isalpha isascii isdecimal isdigit isidentifier islower isnumeric isprintable isspace istitle isupper join ljust lower lstrip maketrans partition removeprefix removesuffix replace rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title translate upper zfill)
  @list ~w(append clear copy count extend index insert pop remove reverse sort)
  @tuple ~w(count index)
  @dict ~w(clear copy fromkeys get items keys pop popitem setdefault update values)
  @int ~w(as_integer_ratio bit_count bit_length conjugate from_bytes to_bytes)
  @float ~w(as_integer_ratio conjugate fromhex hex is_integer)

  @markup ~w(escape striptags unescape)
  # The methods of the Markup class of markupsafe, with their positional-only parameters and
  # their other parameters.
  @markup_signatures %{
    "join" => {["iterable"], []},
    "split" => {[], [{"sep", nil}, {"maxsplit", -1}]},
    "rsplit" => {[], [{"sep", nil}, {"maxsplit", -1}]},
    "splitlines" => {[], [{"keepends", false}]},
    "unescape" => {[], []},
    "striptags" => {[], []},
    "escape" => {["s"], []},
    "capitalize" => {[], []},
    "title" => {[], []},
    "lower" => {[], []},
    "upper" => {[], []},
    "swapcase" => {[], []},
    "casefold" => {[], []},
    "replace" => {["old", "new", {"count", -1}], []},
    "ljust" => {["width", {"fillchar", " "}], []},
    "rjust" => {["width", {"fillchar", " "}], []},
    "center" => {["width", {"fillchar", " "}], []},
    "lstrip" => {[{"chars", nil}], []},
    "rstrip" => {[{"chars", nil}], []},
    "strip" => {[{"chars", nil}], []},
    "translate" => {["table"], []},
    "expandtabs" => {[], [{"tabsize", 8}]},
    "zfill" => {["width"], []},
    "removeprefix" => {["prefix"], []},
    "removesuffix" => {[], ["suffix"]},
    "partition" => {["sep"], []},
    "rpartition" => {["sep"], []}
  }

  @unsafe_list ~w(append clear pop reverse insert sort extend remove)
  @unsafe_dict ~w(clear pop popitem setdefault update)

  @line_breaks [?\n, ?\r, ?\v, ?\f, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]

  @doc """
  Returns true if the Python type of `value` has the method `name`.
  """
  @spec has?(term, String.t()) :: boolean
  def has?(value, name), do: dunder?(name) or name in methods(value)

  # Python objects have many attributes like __class__. The sandbox makes all of them unsafe.
  defp dunder?(name), do: String.starts_with?(name, "__") and String.ends_with?(name, "__")

  defp methods(value) when is_binary(value), do: @str
  defp methods(%Markup{}), do: @str ++ @markup
  defp methods(value) when is_list(value), do: @list
  defp methods(value) when is_tuple(value), do: @tuple
  defp methods(%Dict{}), do: @dict
  defp methods(value) when is_integer(value) or is_boolean(value), do: @int
  defp methods(value) when is_float(value), do: @float
  defp methods(%Otera.Bytes{}), do: ["decode"]
  defp methods(%Otera.Range{}), do: ["count", "index"]
  defp methods(_value), do: []

  @doc """
  Returns false for the methods that change a list or a dict.
  """
  @spec safe?(term, String.t()) :: boolean
  def safe?(_value, "_" <> _), do: false
  def safe?(value, name) when is_list(value), do: name not in @unsafe_list
  def safe?(%Dict{}, name), do: name not in @unsafe_dict
  def safe?(_value, _name), do: true

  @doc """
  Calls the method `name` of `receiver` with positional `args` and a dict of keyword arguments.
  """
  @spec call(term, String.t(), list, Dict.t()) :: term
  def call(receiver, "format", args, kwargs) when is_binary(receiver),
    do: Format.format(receiver, args, kwargs)

  def call(receiver, "format_map", args, kwargs) when is_binary(receiver),
    do: Format.format(receiver, [], format_map_argument(args, kwargs))

  def call(%Markup{} = markup, name, args, kwargs), do: markup_method(markup, name, args, kwargs)

  def call(%Loop{} = loop, "cycle", args, _kwargs) do
    if args == [],
      do: raise(Otera.Error, kind: :type_error, message: "no items for cycling given")

    Enum.at(args, rem(loop.index0, length(args)))
  end

  def call(%Loop{} = loop, "changed", args, _kwargs), do: Loop.changed?(loop, args)

  def call(%Otera.Cycler{} = cycler, name, args, kwargs) do
    check_call(:noargs, "Cycler.#{name}", name, [], args, kwargs)
    Otera.Cycler.call(cycler, name)
  end

  def call(%Otera.GroupTuple{} = group, name, args, kwargs),
    do: call(Otera.GroupTuple.to_tuple(group), name, args, kwargs)

  # A Markup is a str, so the methods of a str take it as a plain string.
  def call(receiver, name, args, kwargs) when is_binary(receiver) do
    {style, params} = signature(receiver, name)
    check_call(style, "str.#{name}", name, params, args, kwargs)
    values = args |> bind(kwargs, params, name) |> Enum.map(&plain/1)
    method(receiver, name, values)
  end

  def call(receiver, name, args, kwargs) do
    {style, params} = signature(receiver, name)
    check_call(style, "#{Value.type_name(receiver)}.#{name}", name, params, args, kwargs)
    method(receiver, name, bind(args, kwargs, params, name))
  end

  defp plain(%Markup{text: text}), do: text
  defp plain(value), do: value

  # The methods of markupsafe: they escape the strings that they add, and most give a Markup.
  # They are Python functions, so they bind their arguments like a Python call, with `self`. The
  # sandbox of Jinja2 runs format and format_map with its own formatter.
  defp markup_method(markup, name, args, kwargs) when name in ["format", "format_map"] do
    {args, kwargs} =
      if name == "format",
        do: {args, kwargs},
        else: {[], format_map_argument(args, kwargs)}

    Markup.new(Format.format(markup.text, args, kwargs, true))
  end

  defp markup_method(markup, name, args, kwargs) when is_map_key(@markup_signatures, name) do
    {positional_only, params} = @markup_signatures[name]

    case Enum.find(kwargs.pairs, fn {key, _} ->
           key in Enum.map(positional_only, &param_name/1)
         end) do
      nil ->
        :ok

      {key, _} ->
        type_error(
          "Markup.#{name}() got some positional-only arguments passed as keyword arguments: #{Value.repr(key)}"
        )
    end

    [_self | values] =
      bind([markup | args], kwargs, ["self" | positional_only ++ params], "Markup.#{name}")

    markupsafe(markup, name, values)
  end

  defp markup_method(markup, name, args, kwargs), do: call(markup.text, name, args, kwargs)

  # The sandbox of Jinja2 checks the arguments of format_map with its own messages.
  defp format_map_argument(_args, %Dict{pairs: [_ | _]}),
    do: type_error("format_map() takes no keyword arguments")

  defp format_map_argument([mapping], _kwargs), do: mapping

  defp format_map_argument(args, _kwargs),
    do: type_error("format_map() takes exactly one argument (#{length(args)} given)")

  defp param_name({name, _default}), do: name
  defp param_name(name), do: name

  defp markupsafe(markup, "join", [items]) do
    text = items |> Value.to_list() |> Enum.map_join(markup.text, &Markup.escape(&1).text)
    Markup.new(text)
  end

  defp markupsafe(_markup, "escape", [value]), do: Markup.escape(value)
  defp markupsafe(markup, "striptags", []), do: HTML.striptags(markup.text)
  defp markupsafe(markup, "unescape", []), do: HTML.unescape(markup.text)

  defp markupsafe(markup, name, values) do
    result = call(markup.text, name, escape_args(name, values), %Dict{})

    cond do
      name in ["split", "rsplit", "splitlines"] ->
        Enum.map(result, &Markup.new/1)

      name in ["partition", "rpartition"] ->
        result |> Tuple.to_list() |> Enum.map(&Markup.new/1) |> List.to_tuple()

      true ->
        Markup.new(result)
    end
  end

  # Markup.replace escapes the new text, and center, ljust and rjust escape the fill character.
  defp escape_args("replace", [old, new | rest]), do: [old, Markup.escape(new) | rest]

  defp escape_args(name, [width, fill]) when name in ["center", "ljust", "rjust"],
    do: [width, Markup.escape(fill)]

  defp escape_args(_name, args), do: args

  # CPython checks the arguments of its builtin methods in a few styles, each with its own messages.
  defp check_call(style, qualified, name, params, args, %Dict{pairs: kwargs}) do
    if message = call_error(style, qualified, name, params, length(args), kwargs),
      do: type_error(message)
  end

  defp call_error(:keywords, _qualified, name, params, given, kwargs) do
    max = length(params)
    unexpected = Enum.find(kwargs, &(elem(&1, 0) not in param_names(params)))

    cond do
      given > max ->
        "#{name}() takes at most #{max} argument#{plural(max)} (#{given} given)"

      unexpected ->
        "#{Value.repr(elem(unexpected, 0))} is an invalid keyword argument for #{name}()"

      true ->
        nil
    end
  end

  defp call_error(:old, _qualified, name, _params, _given, [_ | _]),
    do: "#{name}() takes no keyword arguments"

  defp call_error(_style, qualified, _name, _params, _given, [_ | _]),
    do: "#{qualified}() takes no keyword arguments"

  defp call_error(:noargs, qualified, _name, _params, given, []) when given > 0,
    do: "#{qualified}() takes no arguments (#{given} given)"

  defp call_error(:one, qualified, _name, _params, given, []) when given != 1,
    do: "#{qualified}() takes exactly one argument (#{given} given)"

  defp call_error(style, _qualified, name, params, given, []) when style in [:clinic, :old] do
    min = Enum.count(params, &is_binary/1)
    max = length(params)

    cond do
      given < min and style == :clinic ->
        "#{name} expected at least #{min} argument#{plural(min)}, got #{given}"

      given > max and style == :clinic ->
        "#{name} expected at most #{max} argument#{plural(max)}, got #{given}"

      given < min ->
        "#{name}() takes at least #{min} argument#{plural(min)} (#{given} given)"

      given > max ->
        "#{name}() takes at most #{max} argument#{plural(max)} (#{given} given)"

      true ->
        nil
    end
  end

  defp call_error(_style, _qualified, _name, _params, _given, _kwargs), do: nil

  defp param_names(params), do: Enum.map(params, &if(is_tuple(&1), do: elem(&1, 0), else: &1))

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  @doc """
  Binds positional and keyword arguments to `params`, like a call of a Python function, and returns the values in order. The errors have the messages of Python.

  A param is a name for a required argument, or `{name, default}`.
  """
  @spec bind(list, Dict.t(), list, String.t()) :: list
  def bind(args, %Dict{pairs: kwargs}, params, function) do
    params = Enum.map(params, &if(is_tuple(&1), do: &1, else: {&1, :required}))
    {positional, rest} = Enum.split(params, length(args))
    names = Enum.map(params, &elem(&1, 0))

    cond do
      length(args) > length(params) ->
        type_error(
          "#{function}() takes #{positional_count(params)} but #{given(length(args))} given"
        )

      unexpected = Enum.find(kwargs, fn {name, _} -> name not in names end) ->
        type_error(
          "#{function}() got an unexpected keyword argument #{Value.repr(elem(unexpected, 0))}"
        )

      double = Enum.find(positional, fn {name, _} -> List.keymember?(kwargs, name, 0) end) ->
        type_error(
          "#{function}() got multiple values for argument #{Value.repr(elem(double, 0))}"
        )

      true ->
        args ++ Enum.map(rest, &bind_param(&1, kwargs, rest, function))
    end
  end

  defp bind_param({name, default}, kwargs, rest, function) do
    case List.keyfind(kwargs, name, 0) do
      {_, value} -> value
      nil when default == :required -> missing_arguments(rest, kwargs, function)
      nil -> default
    end
  end

  defp missing_arguments(rest, kwargs, function) do
    missing =
      for {name, :required} <- rest, not List.keymember?(kwargs, name, 0), do: Value.repr(name)

    names =
      case missing do
        [name] -> name
        [first, second] -> "#{first} and #{second}"
        names -> Enum.join(Enum.drop(names, -1), ", ") <> ", and " <> List.last(names)
      end

    plural = if length(missing) == 1, do: "", else: "s"

    type_error(
      "#{function}() missing #{length(missing)} required positional argument#{plural}: #{names}"
    )
  end

  defp positional_count(params) do
    total = length(params)
    required = Enum.count(params, &match?({_, :required}, &1))

    cond do
      required == total and total == 1 -> "1 positional argument"
      required == total -> "#{total} positional arguments"
      true -> "from #{required} to #{total} positional arguments"
    end
  end

  defp given(1), do: "1 was"
  defp given(count), do: "#{count} were"

  defp type_error(message), do: raise(Otera.Error, kind: :type_error, message: message)

  # The style of argument checks of CPython, and the params of each method.
  defp signature(receiver, name) when is_binary(receiver) do
    case name do
      name when name in ~w(strip lstrip rstrip) ->
        {:clinic, [{"chars", nil}]}

      name when name in ~w(split rsplit) ->
        {:keywords, [{"sep", nil}, {"maxsplit", -1}]}

      name when name in ~w(startswith endswith find rfind index rindex count) ->
        {:old, ["sub", {"start", nil}, {"end", nil}]}

      "replace" ->
        {:clinic, ["old", "new", {"count", -1}]}

      name when name in ~w(center ljust rjust) ->
        {:clinic, ["width", {"fillchar", " "}]}

      name
      when name in ~w(join zfill partition rpartition removeprefix removesuffix translate) ->
        {:one, ["arg"]}

      "splitlines" ->
        {:keywords, [{"keepends", false}]}

      "expandtabs" ->
        {:keywords, [{"tabsize", 8}]}

      "encode" ->
        {:keywords, [{"encoding", "utf-8"}, {"errors", "strict"}]}

      _ ->
        {:noargs, []}
    end
  end

  defp signature(%Dict{}, "get"), do: {:clinic, ["key", {"default", nil}]}

  defp signature(sequence, "count") when is_list(sequence) or is_tuple(sequence),
    do: {:one, ["value"]}

  defp signature(sequence, "index") when is_list(sequence) or is_tuple(sequence),
    do: {:clinic, ["value", {"start", 0}, {"stop", nil}]}

  defp signature(%Otera.Range{}, name) when name in ["count", "index"], do: {:one, ["value"]}

  defp signature(%Otera.Bytes{}, "decode"),
    do: {:keywords, [{"encoding", "utf-8"}, {"errors", "strict"}]}

  defp signature(_receiver, _name), do: {:noargs, []}

  ## str

  defp str_method(string, name, [chars]) when name in ~w(strip lstrip rstrip) do
    side = %{"strip" => :both, "lstrip" => :leading, "rstrip" => :trailing}[name]
    Value.strip(string, chars && string_arg(chars, name), side)
  end

  defp str_method(string, "split", [nil, maxsplit]),
    do: string |> String.to_charlist() |> split_whitespace(int_arg(maxsplit), [])

  defp str_method(string, "split", [sep, maxsplit]), do: split(string, sep, maxsplit)

  # Splitting the reversed string from the left splits the string from the right.
  defp str_method(string, "rsplit", [nil, maxsplit]) do
    string
    |> String.to_charlist()
    |> Enum.reverse()
    |> split_whitespace(int_arg(maxsplit), [])
    |> Enum.map(&(&1 |> String.to_charlist() |> Enum.reverse() |> List.to_string()))
    |> Enum.reverse()
  end

  defp str_method(string, "rsplit", [sep, maxsplit]) do
    string
    |> reverse_bytes()
    |> split(reverse_bytes(string_arg(sep, "rsplit")), maxsplit)
    |> Enum.map(&reverse_bytes/1)
    |> Enum.reverse()
  end

  defp str_method(string, name, [prefix, start, stop]) when name in ["startswith", "endswith"] do
    string = Value.slice(string, start, stop, nil)

    prefixes =
      case prefix do
        prefix when is_binary(prefix) ->
          [prefix]

        prefixes when is_tuple(prefixes) ->
          Tuple.to_list(prefixes)

        other ->
          raise Otera.Error,
            kind: :type_error,
            message:
              "#{name} first arg must be str or a tuple of str, not #{Value.type_name(other)}"
      end

    check = if name == "startswith", do: &String.starts_with?/2, else: &String.ends_with?/2
    Enum.any?(prefixes, &check.(string, &1))
  end

  defp str_method(string, name, [sub, start, stop])
       when name in ["find", "rfind", "index", "rindex"] do
    sub = string_arg(sub, name)
    length = Value.str_length(string)
    offset = if (start || 0) < 0, do: max(length + start, 0), else: start || 0
    haystack = Value.slice(string, start, stop, nil)
    position = if offset <= length, do: search(haystack, sub, name in ["rfind", "rindex"])

    case position do
      nil when name in ["index", "rindex"] ->
        raise Otera.Error, kind: :value_error, message: "substring not found"

      nil ->
        -1

      position ->
        offset + position
    end
  end

  defp str_method(string, "count", [sub, start, stop]) do
    haystack = Value.slice(string, start, stop, nil)

    if sub == "",
      do: Value.str_length(haystack) + 1,
      else: length(:binary.matches(haystack, string_arg(sub, "count")))
  end

  defp str_method(string, "replace", [old, new, count]) do
    old = string_arg(old, "replace")
    new = string_arg(new, "replace")

    cond do
      count < 0 and old == "" -> Enum.join([""] ++ String.codepoints(string) ++ [""], new)
      count < 0 -> String.replace(string, old, new)
      old == "" -> replace_empty(String.codepoints(string), new, count)
      true -> string |> String.split(old, parts: count + 1) |> Enum.join(new)
    end
  end

  defp str_method(string, "lower", []), do: String.downcase(string, :greek)
  defp str_method(string, "casefold", []), do: :string.casefold(string)
  defp str_method(string, "upper", []), do: String.upcase(string)
  defp str_method(string, "capitalize", []), do: capitalize(string)
  defp str_method(string, "title", []), do: title(string)

  # Runs of upper case letters lower together, for the final sigma of Greek.
  defp str_method(string, "swapcase", []) do
    string
    |> String.codepoints()
    |> Enum.chunk_by(&uppercase?/1)
    |> Enum.map_join(fn [char | _] = run ->
      if uppercase?(char),
        do: String.downcase(Enum.join(run), :greek),
        else: Enum.map_join(run, &swapcase/1)
    end)
  end

  defp str_method(string, "expandtabs", [tabsize]) do
    {chars, _column} =
      string
      |> String.codepoints()
      |> Enum.map_reduce(0, fn
        "\t", column ->
          spaces = if tabsize > 0, do: tabsize - rem(column, tabsize), else: 0
          {String.duplicate(" ", spaces), column + spaces}

        char, _column when char in ["\n", "\r"] ->
          {char, 0}

        char, column ->
          {char, column + 1}
      end)

    Enum.join(chars)
  end

  defp str_method(string, "join", [items]) do
    items
    |> Value.to_list()
    |> Enum.with_index()
    |> Enum.map_join(string, fn
      {item, _} when is_binary(item) ->
        item

      {%Otera.Markup{text: text}, _} ->
        text

      {item, index} ->
        raise Otera.Error,
          kind: :type_error,
          message: "sequence item #{index}: expected str instance, #{Value.type_name(item)} found"
    end)
  end

  defp str_method(string, "splitlines", [keepends]) do
    string |> String.to_charlist() |> splitlines([], [], Value.truthy?(keepends))
  end

  defp str_method(string, name, [width, fill]) when name in ["center", "ljust", "rjust"] do
    width = int_arg(width)

    cond do
      not is_binary(fill) ->
        type_error("The fill character must be a unicode character, not #{Value.type_name(fill)}")

      Value.str_length(fill) != 1 ->
        type_error("The fill character must be exactly one character long")

      true ->
        :ok
    end

    count = max(width - Value.str_length(string), 0)

    case name do
      "ljust" ->
        string <> String.duplicate(fill, count)

      "rjust" ->
        String.duplicate(fill, count) <> string

      "center" ->
        left = div(count, 2) + Bitwise.band(Bitwise.band(count, width), 1)
        String.duplicate(fill, left) <> string <> String.duplicate(fill, count - left)
    end
  end

  defp str_method(string, "zfill", [width]) do
    {sign, digits} =
      case string do
        <<sign, rest::binary>> when sign in [?+, ?-] -> {<<sign>>, rest}
        string -> {"", string}
      end

    sign <> String.duplicate("0", max(int_arg(width) - Value.str_length(string), 0)) <> digits
  end

  defp str_method(string, "partition", [sep]) do
    case String.split(string, string_arg(sep, "partition"), parts: 2) do
      [before, rest] -> {before, sep, rest}
      [string] -> {string, "", ""}
    end
  end

  defp str_method(string, "rpartition", [sep]) do
    case :binary.matches(string, string_arg(sep, "rpartition")) do
      [] ->
        {"", "", string}

      matches ->
        {pos, len} = List.last(matches)

        {binary_part(string, 0, pos), sep,
         binary_part(string, pos + len, byte_size(string) - pos - len)}
    end
  end

  defp str_method(string, "removeprefix", [prefix]) do
    if String.starts_with?(string, prefix),
      do: binary_part(string, byte_size(prefix), byte_size(string) - byte_size(prefix)),
      else: string
  end

  defp str_method(string, "removesuffix", [suffix]) do
    if suffix != "" and String.ends_with?(string, suffix),
      do: binary_part(string, 0, byte_size(string) - byte_size(suffix)),
      else: string
  end

  defp str_method(string, "isspace", []),
    do: string != "" and string |> String.to_charlist() |> Enum.all?(&Unicode.space?/1)

  defp str_method(string, "isdigit", []), do: all_chars?(string, &Unicode.digit?/1)
  defp str_method(string, "isdecimal", []), do: all_chars?(string, &Unicode.decimal?/1)
  defp str_method(string, "isnumeric", []), do: all_chars?(string, &Unicode.numeric?/1)
  defp str_method(string, "isalpha", []), do: all_chars?(string, &Unicode.alpha?/1)

  defp str_method(string, "isalnum", []),
    do: all_chars?(string, &(Unicode.alpha?(&1) or Unicode.numeric?(&1)))

  defp str_method(string, "isascii", []), do: string =~ ~r/\A[\x00-\x7F]*\z/
  # str.translate looks up each code point in the table: a string, a code point or None.
  defp str_method(string, "translate", [table]) do
    for <<char::utf8 <- string>>, into: "" do
      case translate_lookup(table, char) do
        :error -> <<char::utf8>>
        {:ok, nil} -> ""
        {:ok, text} when is_binary(text) -> text
        {:ok, code} when is_integer(code) -> <<code::utf8>>
        {:ok, _other} -> type_error("character mapping must return integer, None or str")
      end
    end
  end

  defp str_method(string, "encode", [encoding, _errors]),
    do: Otera.Bytes.encode(string, string_arg(encoding, "encode"))

  defp str_method(string, "isidentifier", []),
    do: string =~ ~r/\A[\p{L}\p{Nl}_][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}]*\z/u

  defp str_method(string, "isprintable", []),
    do: string |> String.to_charlist() |> Enum.all?(&Unicode.printable?/1)

  # Python: upper and title case letters only after uncased characters, lower case letters only
  # after cased ones, and at least one cased letter.
  defp str_method(string, "istitle", []) do
    {title?, _previous_cased, any_cased} =
      string
      |> String.codepoints()
      |> Enum.reduce({true, false, false}, fn char, {title?, previous_cased, any_cased} ->
        cond do
          not cased?(char) -> {title?, false, any_cased}
          lowercase?(char) -> {title? and previous_cased, true, true}
          true -> {title? and not previous_cased, true, true}
        end
      end)

    title? and any_cased
  end

  # Python: at least one cased character, and no cased character of the other cases.
  defp str_method(string, "islower", []), do: cases(string) == [:lower]
  defp str_method(string, "isupper", []), do: cases(string) == [:upper]

  defp str_method(string, name, args), do: not_supported(string, name, args)

  defp translate_lookup(%Dict{} = table, char), do: Dict.fetch(table, char)

  defp translate_lookup(table, char) when is_list(table) or is_tuple(table) or is_binary(table) do
    case Value.getitem(table, char) do
      %Otera.Undefined{} -> :error
      value -> {:ok, value}
    end
  end

  defp translate_lookup(table, _char),
    do: type_error("'#{Value.type_name(table)}' object is not subscriptable")

  ## Other types

  defp method(string, name, args) when is_binary(string), do: str_method(string, name, args)

  defp method(%Otera.Bytes{} = bytes, "decode", [encoding, _errors]),
    do: Otera.Bytes.decode(bytes, encoding)

  defp method(sequence, "count", [value]) when is_list(sequence) or is_tuple(sequence),
    do: sequence |> Value.to_list() |> Enum.count(&Value.equal?(&1, value))

  defp method(sequence, "index", [value, start, stop])
       when is_list(sequence) or is_tuple(sequence) do
    items = Value.to_list(sequence)
    offset = if start < 0, do: max(length(items) + start, 0), else: start

    case items |> Value.slice(start, stop, nil) |> Enum.find_index(&Value.equal?(&1, value)) do
      nil ->
        raise Otera.Error,
          kind: :value_error,
          message: "#{Value.repr(value)} is not in #{Value.type_name(sequence)}"

      index ->
        offset + index
    end
  end

  defp method(number, "bit_length", []) when is_integer(number) or is_boolean(number),
    do:
      number
      |> int_arg()
      |> abs()
      |> Integer.digits(2)
      |> then(&if(&1 == [0], do: 0, else: length(&1)))

  defp method(number, "conjugate", []) when is_number(number) or is_boolean(number),
    do: Value.binary_op(:add, number, 0)

  defp method(number, "is_integer", []) when is_float(number), do: number == Float.floor(number)

  defp method(%Otera.Range{} = range, "count", [value]),
    do: if(Otera.Range.member?(range, value), do: 1, else: 0)

  defp method(%Otera.Range{} = range, "index", [value]) do
    case Enum.find_index(Otera.Range.to_list(range), &Value.equal?(&1, value)) do
      nil ->
        raise Otera.Error, kind: :value_error, message: "#{Value.repr(value)} is not in range"

      index ->
        index
    end
  end

  defp method(list, "copy", []) when is_list(list), do: list
  defp method(%Dict{} = dict, "copy", []), do: dict

  defp method(%Dict{} = dict, "get", [key, default]), do: dict_get(dict, key, default)

  defp method(%Dict{pairs: pairs}, "items", []), do: Iterable.new("dict_items", pairs)

  defp method(%Dict{} = dict, "keys", []),
    do: Iterable.new("dict_keys", Dict.keys(dict))

  defp method(%Dict{} = dict, "values", []),
    do: Iterable.new("dict_values", Dict.values(dict))

  defp method(receiver, name, args), do: not_supported(receiver, name, args)

  defp not_supported(receiver, name, _args) do
    raise Otera.Error,
      kind: :not_implemented_error,
      message: "Otera does not support the method #{Value.type_name(receiver)}.#{name}()"
  end

  defp dict_get(%Dict{pairs: pairs}, key, default) do
    case Enum.find(pairs, fn {k, _} -> Value.equal?(k, key) end) do
      {_, value} -> value
      nil -> default
    end
  end

  # Returns the code point index of the first or the last occurrence of `sub`, or nil.
  defp search(haystack, "", reverse?), do: if(reverse?, do: Value.str_length(haystack), else: 0)

  defp search(haystack, sub, false) do
    case :binary.match(haystack, sub) do
      {position, _} -> Value.str_length(binary_part(haystack, 0, position))
      :nomatch -> nil
    end
  end

  # The last occurrence is the first one in the reversed bytes, also when occurrences overlap.
  defp search(haystack, sub, true) do
    case :binary.match(reverse_bytes(haystack), reverse_bytes(sub)) do
      {position, _} ->
        Value.str_length(
          binary_part(haystack, 0, byte_size(haystack) - position - byte_size(sub))
        )

      :nomatch ->
        nil
    end
  end

  defp reverse_bytes(binary),
    do: binary |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp string_arg(value, _name) when is_binary(value), do: value

  defp string_arg(value, name) do
    message =
      case name do
        name when name in ["strip", "lstrip", "rstrip"] ->
          "#{name} arg must be None or str"

        name when name in ["split", "rsplit"] ->
          "must be str or None, not #{Value.type_name(value)}"

        "replace" ->
          "replace() argument 1 must be str, not #{Value.type_name(value)}"

        _ ->
          "must be str, not #{Value.type_name(value)}"
      end

    raise Otera.Error, kind: :type_error, message: message
  end

  defp int_arg(value) when is_integer(value), do: value
  defp int_arg(true), do: 1
  defp int_arg(false), do: 0

  defp int_arg(value),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "'#{Value.type_name(value)}' object cannot be interpreted as an integer"
      )

  # Python splits on runs of whitespace and drops empty strings when `sep` is None.
  defp split(_string, "", _maxsplit),
    do: raise(Otera.Error, kind: :value_error, message: "empty separator")

  defp split(string, sep, maxsplit) do
    case int_arg(maxsplit) do
      maxsplit when maxsplit < 0 -> :binary.split(string, string_arg(sep, "split"), [:global])
      maxsplit -> String.split(string, string_arg(sep, "split"), parts: maxsplit + 1)
    end
  end

  defp split_whitespace(chars, maxsplit, acc) do
    case Enum.drop_while(chars, &Unicode.space?/1) do
      [] ->
        Enum.reverse(acc)

      rest when length(acc) == maxsplit ->
        Enum.reverse([List.to_string(rest) | acc])

      rest ->
        {word, rest} = Enum.split_while(rest, &(not Unicode.space?(&1)))
        split_whitespace(rest, maxsplit, [List.to_string(word) | acc])
    end
  end

  defp splitlines([], [], acc, _keepends), do: Enum.reverse(acc)

  defp splitlines([], line, acc, _keepends),
    do: Enum.reverse([line |> Enum.reverse() |> List.to_string() | acc])

  defp splitlines([?\r, ?\n | rest], line, acc, keepends),
    do:
      splitlines(
        rest,
        [],
        [finish_line(line, if(keepends, do: ~c"\n\r", else: [])) | acc],
        keepends
      )

  defp splitlines([char | rest], line, acc, keepends) when char in @line_breaks,
    do:
      splitlines(
        rest,
        [],
        [finish_line(line, if(keepends, do: [char], else: [])) | acc],
        keepends
      )

  defp splitlines([char | rest], line, acc, keepends),
    do: splitlines(rest, [char | line], acc, keepends)

  defp finish_line(line, ending), do: (ending ++ line) |> Enum.reverse() |> List.to_string()

  defp replace_empty(chars, new, count) do
    {inserted, rest} = Enum.split(chars, max(count - 1, 0))

    if count == 0,
      do: Enum.join(chars),
      else: new <> Enum.map_join(inserted, &(&1 <> new)) <> Enum.join(rest)
  end

  defp capitalize(""), do: ""

  defp capitalize(<<first::utf8, rest::binary>>),
    do: :string.titlecase(<<first::utf8>>) <> String.downcase(rest, :greek)

  # Python title-cases the first character of each run of cased characters, and lowercases the
  # rest of the run, with the final sigma of Greek.
  defp title(string) do
    string
    |> String.codepoints()
    |> Enum.chunk_by(&cased?/1)
    |> Enum.map_join(fn
      [first | rest] = run ->
        if cased?(first),
          do: :string.titlecase(first) <> String.downcase(Enum.join(rest), :greek),
          else: Enum.join(run)
    end)
  end

  defp swapcase(char), do: if(lowercase?(char), do: String.upcase(char), else: char)

  defp all_chars?(string, check),
    do: string != "" and string |> String.to_charlist() |> Enum.all?(check)

  defp cases(string) do
    string
    |> String.to_charlist()
    |> Enum.filter(&Unicode.cased?/1)
    |> Enum.map(fn char ->
      cond do
        Unicode.lowercase?(char) -> :lower
        Unicode.uppercase?(char) -> :upper
        true -> :title
      end
    end)
    |> Enum.uniq()
  end

  defp cased?(<<char::utf8>>), do: Unicode.cased?(char)
  defp lowercase?(<<char::utf8>>), do: Unicode.lowercase?(char)
  defp uppercase?(<<char::utf8>>), do: Unicode.uppercase?(char)
end
