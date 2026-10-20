defmodule Otera.Tests do
  @moduledoc """
  The builtin tests of Jinja2, such as `x is defined` or `x is divisibleby 3`, with their Python behavior.

  The tests are `boolean`, `callable`, `defined`, `divisibleby`, `escaped`, `even`, `false`, `filter`, `float`, `in`, `integer`, `iterable`, `lower`, `mapping`, `none`, `number`, `odd`, `sameas`, `sequence`, `string`, `test`, `true`, `undefined` and `upper`, and the comparisons `eq` (`equalto`, `==`), `ne` (`!=`), `lt` (`lessthan`, `<`), `le` (`<=`), `gt` (`greaterthan`, `>`) and `ge` (`>=`).
  """

  alias Otera.{Dict, Loop, Macro, Method, Methods, Undefined, Value}

  @comparisons %{
    "eq" => :eq,
    "equalto" => :eq,
    "==" => :eq,
    "ne" => :ne,
    "!=" => :ne,
    "lt" => :lt,
    "lessthan" => :lt,
    "<" => :lt,
    "le" => :lteq,
    "<=" => :lteq,
    "gt" => :gt,
    "greaterthan" => :gt,
    ">" => :gt,
    "ge" => :gteq,
    ">=" => :gteq
  }

  @names ~w(boolean callable defined divisibleby escaped even false filter float in integer iterable lower mapping none number odd sameas sequence string test true undefined upper)

  @doc """
  Applies the builtin test `name` to `value`. `env` gives the custom filters and tests for the `filter` and `test` tests.
  """
  @spec call(String.t(), term, list, Dict.t(), map) :: boolean
  def call(name, value, args, kwargs, env)

  def call(name, value, args, kwargs, _env) when is_map_key(@comparisons, name) do
    [other] = Methods.bind(args, kwargs, ["b"], name)

    case @comparisons[name] do
      :eq -> Value.equal?(value, other)
      :ne -> not Value.equal?(value, other)
      op -> Value.compare(op, value, other)
    end
  end

  def call(name, value, args, kwargs, env) when name in @names do
    params = if name in ["divisibleby", "sameas", "in"], do: ["arg"], else: []
    test(name, value, Methods.bind(args, kwargs, params, "test_#{name}"), env)
  end

  def call(name, _value, _args, _kwargs, _env),
    do:
      raise(Otera.Error,
        kind: :template_runtime_error,
        message: "No test named #{Value.repr(name)} found."
      )

  @doc """
  Returns true if `name` is a builtin test.
  """
  @spec builtin?(String.t()) :: boolean
  def builtin?(name), do: name in @names or is_map_key(@comparisons, name)

  defp test("defined", value, [], _env), do: not is_struct(value, Undefined)
  defp test("undefined", value, [], _env), do: is_struct(value, Undefined)
  defp test("none", value, [], _env), do: value == nil
  defp test("boolean", value, [], _env), do: is_boolean(value)
  defp test("true", value, [], _env), do: value === true
  defp test("false", value, [], _env), do: value === false
  defp test("integer", value, [], _env), do: is_integer(value)
  defp test("float", value, [], _env), do: is_float(value)
  defp test("number", value, [], _env), do: is_number(value) or is_boolean(value)
  defp test("string", value, [], _env), do: is_binary(value)
  defp test("mapping", value, [], _env), do: is_struct(value, Dict)

  defp test("sequence", value, [], _env),
    do:
      is_binary(value) or is_list(value) or is_tuple(value) or is_struct(value, Dict) or
        is_struct(value, Undefined)

  defp test("iterable", value, [], _env), do: Value.iterable?(value) or is_struct(value, Loop)

  defp test("callable", value, [], _env),
    do:
      is_function(value) or is_struct(value, Macro) or is_struct(value, Method) or
        is_struct(value, Loop) or is_struct(value, Undefined)

  defp test("escaped", _value, [], _env), do: false

  defp test("lower", value, [], _env),
    do: Methods.call(Value.to_str(value), "islower", [], %Dict{})

  defp test("upper", value, [], _env),
    do: Methods.call(Value.to_str(value), "isupper", [], %Dict{})

  defp test("odd", value, [], _env), do: Value.equal?(Value.binary_op(:mod, value, 2), 1)
  defp test("even", value, [], _env), do: Value.equal?(Value.binary_op(:mod, value, 2), 0)

  defp test("divisibleby", value, [num], _env),
    do: Value.equal?(Value.binary_op(:mod, value, num), 0)

  defp test("in", value, [sequence], _env), do: Value.contains?(sequence, value)

  defp test("sameas", value, [other], _env),
    do:
      value === other or
        (is_number(value) and Value.equal?(value, other) and
           is_integer(value) == is_integer(other))

  defp test("filter", value, [], env),
    do: Otera.Filters.builtin?(value) or is_map_key(env.filters, value)

  defp test("test", value, [], env), do: builtin?(value) or is_map_key(env.tests, value)
end
