defmodule Otera.Methods do
  @moduledoc """
  The Python methods that templates call on values, such as `content.strip()`, `name.startswith("get_")` or `message.get("tool_calls")`.

  `has?/2` knows every method of the Python types `str`, `list`, `tuple`, `dict`, `int` and `float`, because a method name hides a dict key of the same name in `x.name`. `call/4` runs the methods that chat templates use. As in the immutable sandbox of transformers, the methods that change a list or a dict are unsafe.
  """

  alias Otera.{Dict, Format, Iterable, Loop, Value}

  @str ~w(capitalize casefold center count encode endswith expandtabs find format format_map index isalnum isalpha isascii isdecimal isdigit isidentifier islower isnumeric isprintable isspace istitle isupper join ljust lower lstrip maketrans partition removeprefix removesuffix replace rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title translate upper zfill)
  @list ~w(append clear copy count extend index insert pop remove reverse sort)
  @tuple ~w(count index)
  @dict ~w(clear copy fromkeys get items keys pop popitem setdefault update values)
  @int ~w(as_integer_ratio bit_count bit_length conjugate from_bytes to_bytes)
  @float ~w(as_integer_ratio conjugate fromhex hex is_integer)

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
  defp methods(value) when is_list(value), do: @list
  defp methods(value) when is_tuple(value), do: @tuple
  defp methods(%Dict{}), do: @dict
  defp methods(value) when is_integer(value) or is_boolean(value), do: @int
  defp methods(value) when is_float(value), do: @float
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

  def call(receiver, "format_map", [%Dict{} = mapping], %Dict{pairs: []})
      when is_binary(receiver),
      do: Format.format(receiver, [], mapping)

  def call(%Loop{} = loop, "cycle", args, _kwargs) do
    if args == [],
      do: raise(Otera.Error, kind: :type_error, message: "no items for cycling given")

    Enum.at(args, rem(loop.index0, length(args)))
  end

  def call(%Loop{} = loop, "changed", args, _kwargs), do: Loop.changed?(loop, args)

  def call(receiver, name, args, kwargs) do
    method(receiver, name, bind(args, kwargs, params(receiver, name), name))
  end

  @doc """
  Binds positional and keyword arguments to `params`, like a Python call, and returns the values in order.

  A param is a name for a required argument, or `{name, default}`.
  """
  @spec bind(list, Dict.t(), list, String.t()) :: list
  def bind(args, %Dict{pairs: kwargs}, params, function) do
    if length(args) > length(params) do
      raise Otera.Error,
        kind: :type_error,
        message: "#{function}() takes at most #{length(params)} arguments (#{length(args)} given)"
    end

    params = Enum.map(params, &if(is_tuple(&1), do: &1, else: {&1, :required}))
    names = Enum.map(params, &elem(&1, 0))

    case Enum.find(kwargs, fn {name, _} -> name not in names end) do
      nil ->
        {values, _} = Enum.map_reduce(params, args, &bind_param(&1, &2, kwargs, function))
        values

      {name, _} ->
        raise Otera.Error,
          kind: :type_error,
          message: "#{function}() got an unexpected keyword argument #{Value.repr(name)}"
    end
  end

  defp bind_param(_param, [arg | rest], _kwargs, _function), do: {arg, rest}

  defp bind_param({name, default}, [], kwargs, function) do
    case List.keyfind(kwargs, name, 0) do
      {_, value} -> {value, []}
      nil when default == :required -> missing_argument(function, name)
      nil -> {default, []}
    end
  end

  defp missing_argument(function, name),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "#{function}() missing required argument: #{Value.repr(name)}"
      )

  defp params(receiver, name) when is_binary(receiver) do
    case name do
      name when name in ~w(strip lstrip rstrip) ->
        [{"chars", nil}]

      name when name in ~w(split rsplit) ->
        [{"sep", nil}, {"maxsplit", -1}]

      name when name in ~w(startswith endswith find rfind index rindex count) ->
        ["sub", {"start", nil}, {"end", nil}]

      "replace" ->
        ["old", "new", {"count", -1}]

      name when name in ~w(center ljust rjust) ->
        ["width", {"fillchar", " "}]

      name when name in ~w(join zfill partition rpartition removeprefix removesuffix) ->
        ["arg"]

      "splitlines" ->
        [{"keepends", false}]

      "expandtabs" ->
        [{"tabsize", 8}]

      _ ->
        []
    end
  end

  defp params(%Dict{}, "get"), do: ["key", {"default", nil}]

  defp params(sequence, name)
       when name in ["count", "index"] and (is_list(sequence) or is_tuple(sequence)),
       do: ["value"]

  defp params(_receiver, _name), do: []

  ## str

  defp method(string, name, [chars]) when name in ~w(strip lstrip rstrip) do
    side = %{"strip" => :both, "lstrip" => :leading, "rstrip" => :trailing}[name]
    Value.strip(string, chars && string_arg(chars, name), side)
  end

  defp method(string, "split", [nil, maxsplit]),
    do: string |> String.to_charlist() |> split_whitespace(int_arg(maxsplit), [])

  defp method(string, "split", [sep, maxsplit]), do: split(string, sep, maxsplit)

  # Splitting the reversed string from the left splits the string from the right.
  defp method(string, "rsplit", [nil, maxsplit]) do
    string
    |> String.to_charlist()
    |> Enum.reverse()
    |> split_whitespace(int_arg(maxsplit), [])
    |> Enum.map(&(&1 |> String.to_charlist() |> Enum.reverse() |> List.to_string()))
    |> Enum.reverse()
  end

  defp method(string, "rsplit", [sep, maxsplit]) do
    string
    |> reverse_bytes()
    |> split(reverse_bytes(string_arg(sep, "rsplit")), maxsplit)
    |> Enum.map(&reverse_bytes/1)
    |> Enum.reverse()
  end

  defp method(string, name, [prefix, start, stop]) when name in ["startswith", "endswith"] do
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

  defp method(string, name, [sub, start, stop])
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

  defp method(string, "count", [sub, start, stop]) do
    haystack = Value.slice(string, start, stop, nil)

    if sub == "",
      do: Value.str_length(haystack) + 1,
      else: length(:binary.matches(haystack, string_arg(sub, "count")))
  end

  defp method(string, "replace", [old, new, count]) do
    old = string_arg(old, "replace")
    new = string_arg(new, "replace")

    cond do
      count < 0 and old == "" -> Enum.join([""] ++ String.codepoints(string) ++ [""], new)
      count < 0 -> String.replace(string, old, new)
      old == "" -> replace_empty(String.codepoints(string), new, count)
      true -> string |> String.split(old, parts: count + 1) |> Enum.join(new)
    end
  end

  defp method(string, "lower", []), do: String.downcase(string, :greek)
  defp method(string, "casefold", []), do: :string.casefold(string)
  defp method(string, "upper", []), do: String.upcase(string)
  defp method(string, "capitalize", []), do: capitalize(string)
  defp method(string, "title", []), do: title(string)

  defp method(string, "swapcase", []),
    do: string |> String.codepoints() |> Enum.map_join(&swapcase/1)

  defp method(string, "expandtabs", [tabsize]) do
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

  defp method(string, "join", [items]) do
    items
    |> Value.to_list()
    |> Enum.with_index()
    |> Enum.map_join(string, fn
      {item, _} when is_binary(item) ->
        item

      {item, index} ->
        raise Otera.Error,
          kind: :type_error,
          message: "sequence item #{index}: expected str instance, #{Value.type_name(item)} found"
    end)
  end

  defp method(string, "splitlines", [keepends]) do
    string |> String.to_charlist() |> splitlines([], [], Value.truthy?(keepends))
  end

  defp method(string, name, [width, fill]) when name in ["center", "ljust", "rjust"] do
    width = int_arg(width)
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

  defp method(string, "zfill", [width]) do
    {sign, digits} =
      case string do
        <<sign, rest::binary>> when sign in [?+, ?-] -> {<<sign>>, rest}
        string -> {"", string}
      end

    sign <> String.duplicate("0", max(int_arg(width) - Value.str_length(string), 0)) <> digits
  end

  defp method(string, "partition", [sep]) do
    case String.split(string, string_arg(sep, "partition"), parts: 2) do
      [before, rest] -> {before, sep, rest}
      [string] -> {string, "", ""}
    end
  end

  defp method(string, "rpartition", [sep]) do
    case :binary.matches(string, string_arg(sep, "rpartition")) do
      [] ->
        {"", "", string}

      matches ->
        {pos, len} = List.last(matches)

        {binary_part(string, 0, pos), sep,
         binary_part(string, pos + len, byte_size(string) - pos - len)}
    end
  end

  defp method(string, "removeprefix", [prefix]) do
    if String.starts_with?(string, prefix),
      do: binary_part(string, byte_size(prefix), byte_size(string) - byte_size(prefix)),
      else: string
  end

  defp method(string, "removesuffix", [suffix]) do
    if suffix != "" and String.ends_with?(string, suffix),
      do: binary_part(string, 0, byte_size(string) - byte_size(suffix)),
      else: string
  end

  defp method(string, "isspace", []),
    do: string != "" and string |> String.to_charlist() |> Enum.all?(&Value.whitespace?/1)

  defp method(string, "isdigit", []), do: string =~ ~r/\A\p{Nd}+\z/u
  defp method(string, "isdecimal", []), do: string =~ ~r/\A\p{Nd}+\z/u
  defp method(string, "isnumeric", []), do: string =~ ~r/\A\p{N}+\z/u
  defp method(string, "isalpha", []), do: string =~ ~r/\A\p{L}+\z/u
  defp method(string, "isalnum", []), do: string =~ ~r/\A[\p{L}\p{N}]+\z/u
  defp method(string, "isascii", []), do: string =~ ~r/\A[\x00-\x7F]*\z/

  defp method(string, "isidentifier", []),
    do: string =~ ~r/\A[\p{L}\p{Nl}_][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}]*\z/u

  defp method(string, "isprintable", []),
    do: string |> String.to_charlist() |> Enum.all?(&Value.printable?/1)

  # Python: upper and title case letters only after uncased characters, lower case letters only
  # after cased ones, and at least one cased letter.
  defp method(string, "istitle", []) do
    {title?, _previous_cased, any_cased} =
      string
      |> String.codepoints()
      |> Enum.reduce({true, false, false}, fn char, {title?, previous_cased, any_cased} ->
        cond do
          not cased?(char) -> {title?, false, any_cased}
          String.downcase(char) != char -> {title? and not previous_cased, true, true}
          true -> {title? and previous_cased, true, true}
        end
      end)

    title? and any_cased
  end

  defp method(string, "islower", []), do: cased?(string) and String.downcase(string) == string
  defp method(string, "isupper", []), do: cased?(string) and String.upcase(string) == string

  ## list, tuple and dict

  defp method(sequence, "count", [value]) when is_list(sequence) or is_tuple(sequence),
    do: sequence |> Value.to_list() |> Enum.count(&Value.equal?(&1, value))

  defp method(sequence, "index", [value]) when is_list(sequence) or is_tuple(sequence) do
    case Enum.find_index(Value.to_list(sequence), &Value.equal?(&1, value)) do
      nil ->
        raise Otera.Error,
          kind: :value_error,
          message: "#{Value.repr(value)} is not in #{Value.type_name(sequence)}"

      index ->
        index
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

  defp method(list, "copy", []) when is_list(list), do: list
  defp method(%Dict{} = dict, "copy", []), do: dict

  defp method(%Dict{} = dict, "get", [key, default]), do: dict_get(dict, key, default)

  defp method(%Dict{pairs: pairs}, "items", []), do: %Iterable{type: "dict_items", items: pairs}

  defp method(%Dict{} = dict, "keys", []),
    do: %Iterable{type: "dict_keys", items: Dict.keys(dict)}

  defp method(%Dict{} = dict, "values", []),
    do: %Iterable{type: "dict_values", items: Dict.values(dict)}

  defp method(receiver, name, _args) do
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
    case Enum.drop_while(chars, &Value.whitespace?/1) do
      [] ->
        Enum.reverse(acc)

      rest when length(acc) == maxsplit ->
        Enum.reverse([List.to_string(rest) | acc])

      rest ->
        {word, rest} = Enum.split_while(rest, &(not Value.whitespace?(&1)))
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

  defp swapcase(char) do
    cond do
      String.downcase(char) != char and String.upcase(char) == char -> String.downcase(char)
      String.upcase(char) != char and String.downcase(char) == char -> String.upcase(char)
      true -> char
    end
  end

  defp cased?(string), do: String.upcase(string) != String.downcase(string)
end
