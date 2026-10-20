defmodule Otera.Evaluator do
  @moduledoc """
  Renders the syntax tree of `Otera.Parser` with the semantics of Python Jinja2.

  The evaluator keeps a stack of scopes. The last scope holds the variables of the render and the top-level assignments. A `for` iteration, a macro call, a `with` block and the body of a `set`, `filter` or `generation` block run in a new scope, so their assignments do not leak out, as in Jinja2. A macro reads the top-level scope as it is at call time. Namespaces are the one way to change state across scopes.

  `break` and `continue` stop the rest of a loop body. As in Jinja2, the `else` block of a loop runs when no iteration reached the end of the body.
  """

  alias Otera.{
    Dict,
    Filters,
    Loop,
    Macro,
    Method,
    Methods,
    Namespace,
    State,
    Tests,
    Undefined,
    Value
  }

  defstruct frames: [], filters: %{}, tests: %{}, globals: %{}

  @builtins ["range", "dict", "namespace"]
  @max_range 100_000

  @doc """
  Renders `ast` with `variables`, a map with string keys. Raises `Otera.Error`.

  Options: `:filters`, `:tests` and `:globals`, maps from names to Elixir functions or values.
  """
  @spec render(list, map, keyword) :: String.t()
  def render(ast, variables, opts) do
    ctx = %__MODULE__{
      frames: [variables],
      filters: names(Keyword.get(opts, :filters, %{})),
      tests: names(Keyword.get(opts, :tests, %{})),
      globals:
        Map.new(Keyword.get(opts, :globals, %{}), fn {name, value} ->
          {to_string(name), Value.from_elixir(value)}
        end)
    }

    State.run(fn ->
      {output, _ctx, _signal} = exec_body(ast, ctx)
      IO.iodata_to_binary(output)
    end)
  end

  defp names(map), do: Map.new(map, fn {name, value} -> {to_string(name), value} end)

  ## Statements

  defp exec_body(nodes, ctx), do: exec_body(nodes, ctx, [])

  defp exec_body([], ctx, acc), do: {acc, ctx, :ok}

  defp exec_body([node | rest], ctx, acc) do
    case exec(node, ctx) do
      {output, ctx, :ok} -> exec_body(rest, ctx, [acc | output])
      {output, ctx, signal} -> {[acc | output], ctx, signal}
    end
  end

  defp exec({:text, text}, ctx), do: {text, ctx, :ok}
  defp exec({:output, expr}, ctx), do: {Value.to_str(eval(expr, ctx)), ctx, :ok}
  defp exec(:break, ctx), do: {[], ctx, :break}
  defp exec(:continue, ctx), do: {[], ctx, :continue}

  defp exec({:if, branches, else_body}, ctx) do
    case Enum.find(branches, fn {test, _body} -> Value.truthy?(eval(test, ctx)) end) do
      {_test, body} -> exec_body(body, ctx)
      nil -> exec_body(else_body, ctx)
    end
  end

  defp exec({:set, target, expr}, ctx), do: {[], assign(target, eval(expr, ctx), ctx), :ok}

  defp exec({:set_block, target, filter, body}, ctx) do
    value = capture(body, ctx)
    value = if filter, do: eval(fill_hole(filter, value), ctx), else: value
    {[], assign(target, value, ctx), :ok}
  end

  defp exec({:for, _target, iter, _test, _body, _else_body, _recursive?} = node, ctx),
    do: loop(node, eval(iter, ctx), ctx, 0)

  defp exec({:macro, name, params, body, special_names}, ctx) do
    macro = %Macro{
      name: name,
      params: params,
      body: body,
      special_names: special_names,
      frames: closure(ctx)
    }

    {[], put_var(ctx, name, macro), :ok}
  end

  defp exec({:call_block, {:call, callee, args, kwargs}, params, body, special_names}, ctx) do
    caller = %Macro{
      name: nil,
      params: params,
      body: body,
      special_names: special_names,
      frames: closure(ctx)
    }

    {args, %Dict{} = kwargs} = eval_args(args, kwargs, ctx)
    value = call_value(eval(callee, ctx), args, Dict.put(kwargs, "caller", caller), ctx)
    {Value.to_str(value), ctx, :ok}
  end

  defp exec({:filter_block, filter, body}, ctx),
    do: {Value.to_str(eval(fill_hole(filter, capture(body, ctx)), ctx)), ctx, :ok}

  defp exec({:with, assignments, body}, ctx) do
    frame =
      Enum.reduce(assignments, %{}, fn {target, expr}, frame ->
        Map.merge(frame, bind(target, eval(expr, ctx)))
      end)

    {output, _inner, signal} = exec_body(body, push(ctx, frame))
    {output, ctx, signal}
  end

  defp exec({:generation, body}, ctx), do: {capture(body, ctx), ctx, :ok}

  defp capture(body, ctx) do
    {output, _inner, _signal} = exec_body(body, push(ctx, %{}))
    IO.iodata_to_binary(output)
  end

  defp fill_hole({:filter, name, nil, args, kwargs, line}, value),
    do: {:filter, name, {:const, value}, args, kwargs, line}

  defp fill_hole({:filter, name, inner, args, kwargs, line}, value),
    do: {:filter, name, fill_hole(inner, value), args, kwargs, line}

  defp loop(
         {:for, target, _iter, test, body, else_body, recursive?} = node,
         iterable,
         ctx,
         depth0
       ) do
    items = Value.to_list(iterable)

    items =
      if test,
        do: Enum.filter(items, &Value.truthy?(eval(test, push(ctx, bind(target, &1))))),
        else: items

    items = List.to_tuple(items)
    recurse = if recursive?, do: {node, ctx}
    ref = make_ref()

    {output, completed?} =
      Enum.reduce_while(0..(tuple_size(items) - 1)//1, {[], false}, fn index, {acc, completed?} ->
        loop = %Loop{ref: ref, items: items, index0: index, depth0: depth0, recurse: recurse}
        frame = target |> bind(elem(items, index)) |> Map.put("loop", loop)
        {output, _inner, signal} = exec_body(body, push(ctx, frame))

        case signal do
          :ok -> {:cont, {[acc | output], true}}
          :continue -> {:cont, {[acc | output], completed?}}
          :break -> {:halt, {[acc | output], completed?}}
        end
      end)

    if completed? or else_body == [] do
      {output, ctx, :ok}
    else
      {else_output, _inner, signal} = exec_body(else_body, push(ctx, %{}))
      {[output | else_output], ctx, signal}
    end
  end

  defp assign({:ns_ref, name, attr}, value, ctx) do
    case lookup(ctx, name) do
      %Namespace{} = namespace ->
        Namespace.put(namespace, attr, value)
        ctx

      _other ->
        raise Otera.Error,
          kind: :template_runtime_error,
          message: "cannot assign attribute on non-namespace object"
    end
  end

  defp assign({:tuple, targets}, value, ctx) do
    targets
    |> Enum.zip(unpack(value, length(targets)))
    |> Enum.reduce(ctx, fn {target, item}, ctx -> assign(target, item, ctx) end)
  end

  defp assign({:name, name}, value, ctx), do: put_var(ctx, name, value)

  defp bind({:name, name}, value), do: %{name => value}

  defp bind({:tuple, targets}, value) do
    targets
    |> Enum.zip(unpack(value, length(targets)))
    |> Enum.reduce(%{}, fn {target, item}, frame -> Map.merge(frame, bind(target, item)) end)
  end

  defp unpack(value, count) do
    unless Value.iterable?(value) do
      raise Otera.Error,
        kind: :type_error,
        message: "cannot unpack non-iterable #{Value.type_name(value)} object"
    end

    items = Value.to_list(value)

    cond do
      length(items) > count ->
        raise Otera.Error,
          kind: :value_error,
          message: "too many values to unpack (expected #{count})"

      length(items) < count ->
        raise Otera.Error,
          kind: :value_error,
          message: "not enough values to unpack (expected #{count}, got #{length(items)})"

      true ->
        items
    end
  end

  ## Scopes

  defp push(ctx, frame), do: %{ctx | frames: [frame | ctx.frames]}

  defp put_var(%{frames: [frame | rest]} = ctx, name, value),
    do: %{ctx | frames: [Map.put(frame, name, value) | rest]}

  # A macro sees the scopes around its definition, and the top-level scope at call time.
  defp closure(ctx), do: Enum.drop(ctx.frames, -1)

  defp lookup(ctx, name) do
    case Enum.find(ctx.frames, &is_map_key(&1, name)) do
      %{^name => value} -> value
      nil -> global(ctx, name)
    end
  end

  defp global(ctx, name) do
    case ctx.globals do
      %{^name => value} -> value
      _ when name in @builtins -> %Method{receiver: :builtins, name: name}
      _ -> %Undefined{name: name}
    end
  end

  ## Expressions

  defp eval({:const, value}, _ctx), do: value
  defp eval({:name, name}, ctx), do: lookup(ctx, name)
  defp eval({:list, items}, ctx), do: Enum.map(items, &eval(&1, ctx))
  defp eval({:tuple, items}, ctx), do: items |> Enum.map(&eval(&1, ctx)) |> List.to_tuple()

  defp eval({:dict, pairs}, ctx) do
    pairs
    |> Enum.map(fn {key, value} -> {eval(key, ctx), eval(value, ctx)} end)
    |> tap(&Enum.each(&1, fn {key, _value} -> Value.hashable!(key) end))
    |> Dict.new()
  end

  defp eval({:getattr, expr, name}, ctx), do: Value.getattr(eval(expr, ctx), name)

  defp eval({:getitem, expr, {:slice, start, stop, step}}, ctx),
    do:
      Value.slice(
        eval(expr, ctx),
        eval_optional(start, ctx),
        eval_optional(stop, ctx),
        eval_optional(step, ctx)
      )

  defp eval({:getitem, expr, key}, ctx), do: Value.getitem(eval(expr, ctx), eval(key, ctx))
  defp eval({:not, expr}, ctx), do: not Value.truthy?(eval(expr, ctx))
  defp eval({:neg, expr}, ctx), do: Value.unary_op(:neg, eval(expr, ctx))
  defp eval({:pos, expr}, ctx), do: Value.unary_op(:pos, eval(expr, ctx))

  defp eval({:and, left, right}, ctx) do
    left = eval(left, ctx)
    if Value.truthy?(left), do: eval(right, ctx), else: left
  end

  defp eval({:or, left, right}, ctx) do
    left = eval(left, ctx)
    if Value.truthy?(left), do: left, else: eval(right, ctx)
  end

  defp eval({:binop, op, left, right}, ctx),
    do: Value.binary_op(op, eval(left, ctx), eval(right, ctx))

  defp eval({:concat, exprs}, ctx), do: Enum.map_join(exprs, &Value.to_str(eval(&1, ctx)))
  defp eval({:compare, expr, ops}, ctx), do: compare(eval(expr, ctx), ops, ctx)

  defp eval({:cond, test, then_expr, else_expr}, ctx) do
    if Value.truthy?(eval(test, ctx)), do: eval(then_expr, ctx), else: eval(else_expr, ctx)
  end

  defp eval({:call, callee, args, kwargs}, ctx) do
    callee = eval(callee, ctx)
    {args, kwargs} = eval_args(args, kwargs, ctx)
    call_value(callee, args, kwargs, ctx)
  end

  defp eval({:filter, name, expr, args, kwargs, _line}, ctx) do
    value = eval(expr, ctx)
    {args, kwargs} = eval_args(args, kwargs, ctx)
    call_filter(ctx, name, value, args, kwargs)
  end

  defp eval({:test, name, expr, args, kwargs, _line}, ctx) do
    value = eval(expr, ctx)
    {args, kwargs} = eval_args(args, kwargs, ctx)
    call_test(ctx, name, value, args, kwargs)
  end

  defp eval_optional(nil, _ctx), do: nil
  defp eval_optional(expr, ctx), do: eval(expr, ctx)

  defp compare(_left, [], _ctx), do: true

  defp compare(left, [{op, expr} | rest], ctx) do
    right = eval(expr, ctx)

    result =
      case op do
        :eq -> Value.equal?(left, right)
        :ne -> not Value.equal?(left, right)
        :in -> Value.contains?(right, left)
        :notin -> not Value.contains?(right, left)
        op -> Value.compare(op, left, right)
      end

    result and compare(right, rest, ctx)
  end

  defp eval_args(args, kwargs, ctx) do
    args =
      Enum.flat_map(args, fn
        {:unpack, expr} -> unpack_args(eval(expr, ctx))
        expr -> [eval(expr, ctx)]
      end)

    pairs =
      Enum.flat_map(kwargs, fn
        {:unpack, expr} -> unpack_kwargs(eval(expr, ctx))
        {name, expr} -> [{name, eval(expr, ctx)}]
      end)

    {args, Dict.new(pairs)}
  end

  defp unpack_args(value) do
    if Value.iterable?(value),
      do: Value.to_list(value),
      else:
        raise(Otera.Error,
          kind: :type_error,
          message: "Value after * must be an iterable, not #{Value.type_name(value)}"
        )
  end

  defp unpack_kwargs(%Dict{pairs: pairs}), do: pairs

  defp unpack_kwargs(value),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "argument after ** must be a mapping, not #{Value.type_name(value)}"
      )

  ## Calls

  @doc """
  Applies the filter `name`: a custom filter of `ctx`, or else a builtin filter. `Otera.Filters` calls it for `map`.
  """
  @spec call_filter(%__MODULE__{}, String.t(), term, list, Dict.t()) :: term
  def call_filter(ctx, name, value, args, kwargs) do
    case ctx.filters do
      %{^name => fun} -> call_function(fun, [value | args], kwargs)
      _ -> Filters.call(name, value, args, kwargs, ctx)
    end
  end

  @doc """
  Applies the test `name`: a custom test of `ctx`, or else a builtin test. `Otera.Filters` calls it for `select`.
  """
  @spec call_test(%__MODULE__{}, String.t(), term, list, Dict.t()) :: boolean
  def call_test(ctx, name, value, args, kwargs) do
    case ctx.tests do
      %{^name => fun} -> Value.truthy?(call_function(fun, [value | args], kwargs))
      _ -> Tests.call(name, value, args, kwargs, ctx)
    end
  end

  defp call_value(%Macro{} = macro, args, kwargs, ctx), do: call_macro(macro, args, kwargs, ctx)

  defp call_value(%Method{receiver: :builtins, name: name}, args, kwargs, _ctx),
    do: builtin(name, args, kwargs)

  defp call_value(%Method{receiver: receiver, name: name}, args, kwargs, _ctx),
    do: Methods.call(receiver, name, args, kwargs)

  defp call_value(%Loop{recurse: {node, loop_ctx}, depth0: depth0}, [iterable], _kwargs, _ctx) do
    {output, _ctx, _signal} = loop(node, iterable, loop_ctx, depth0 + 1)
    IO.iodata_to_binary(output)
  end

  defp call_value(%Loop{}, _args, _kwargs, _ctx),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "The loop must have the 'recursive' marker to be called recursively."
      )

  defp call_value(%Undefined{} = undefined, _args, _kwargs, _ctx), do: Undefined.fail(undefined)

  defp call_value(fun, args, kwargs, _ctx) when is_function(fun),
    do: call_function(fun, args, kwargs)

  defp call_value(value, _args, _kwargs, _ctx),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "'#{Value.type_name(value)}' object is not callable"
      )

  # An Elixir function gets the keyword arguments as a final map when it takes one more argument.
  defp call_function(fun, args, %Dict{pairs: pairs}) do
    {:arity, arity} = Function.info(fun, :arity)

    cond do
      arity == length(args) and pairs == [] ->
        fun |> apply(args) |> Value.from_elixir()

      arity == length(args) + 1 ->
        fun |> apply(args ++ [Map.new(pairs)]) |> Value.from_elixir()

      true ->
        raise Otera.Error,
          kind: :type_error,
          message: "the function takes #{arity} arguments, but the template gave #{length(args)}"
    end
  end

  defp call_macro(macro, args, kwargs, ctx) do
    {positional, extra} = Enum.split(args, length(macro.params))
    macro_ctx = %{ctx | frames: [%{}] ++ macro.frames ++ [List.last(ctx.frames)]}
    {macro_ctx, kwargs} = bind_params(macro_ctx, macro.params, positional, kwargs)
    {macro_ctx, kwargs} = bind_caller(macro_ctx, macro, kwargs)
    macro_ctx = macro_ctx |> bind_kwargs(macro, kwargs) |> bind_varargs(macro, extra)
    {output, _ctx, _signal} = exec_body(macro.body, macro_ctx)
    IO.iodata_to_binary(output)
  end

  # Positional arguments come first, then keyword arguments, then defaults, which can read the
  # parameters before them.
  defp bind_params(ctx, params, positional, kwargs) do
    {named, rest} = Enum.split(params, length(positional))

    ctx =
      named
      |> Enum.zip(positional)
      |> Enum.reduce(ctx, fn {{name, _default}, value}, ctx -> put_var(ctx, name, value) end)

    Enum.reduce(rest, {ctx, kwargs}, &bind_param/2)
  end

  defp bind_param({name, default}, {ctx, kwargs}) do
    value =
      case Dict.fetch(kwargs, name) do
        {:ok, value} -> value
        :error when default != nil -> eval(default, ctx)
        :error -> %Undefined{hint: "parameter #{Value.repr(name)} was not provided", name: name}
      end

    {put_var(ctx, name, value), dict_delete(kwargs, name)}
  end

  defp bind_caller(ctx, macro, kwargs) do
    if "caller" in macro.special_names and not Enum.any?(macro.params, &(elem(&1, 0) == "caller")) do
      caller =
        case Dict.fetch(kwargs, "caller") do
          {:ok, caller} -> caller
          :error -> %Undefined{hint: "No caller defined", name: "caller"}
        end

      {put_var(ctx, "caller", caller), dict_delete(kwargs, "caller")}
    else
      {ctx, kwargs}
    end
  end

  defp bind_kwargs(ctx, macro, kwargs) do
    cond do
      "kwargs" in macro.special_names ->
        put_var(ctx, "kwargs", kwargs)

      kwargs.pairs == [] ->
        ctx

      Dict.fetch(kwargs, "caller") != :error ->
        macro_error(
          macro,
          "was invoked with two values for the special caller argument. This is most likely a bug."
        )

      true ->
        macro_error(
          macro,
          "takes no keyword argument #{Value.repr(kwargs.pairs |> hd() |> elem(0))}"
        )
    end
  end

  defp bind_varargs(ctx, macro, extra) do
    cond do
      "varargs" in macro.special_names -> put_var(ctx, "varargs", List.to_tuple(extra))
      extra == [] -> ctx
      true -> macro_error(macro, "takes not more than #{length(macro.params)} argument(s)")
    end
  end

  defp dict_delete(%Dict{pairs: pairs}, key), do: %Dict{pairs: List.keydelete(pairs, key, 0)}

  defp macro_error(macro, message),
    do:
      raise(Otera.Error, kind: :type_error, message: "macro #{Value.repr(macro.name)} #{message}")

  defp builtin("range", args, %Dict{pairs: []}) do
    {start, stop, step} =
      case Enum.map(args, &range_integer/1) do
        [stop] ->
          {0, stop, 1}

        [start, stop] ->
          {start, stop, 1}

        [start, stop, step] ->
          {start, stop, step}

        _ ->
          raise Otera.Error,
            kind: :type_error,
            message: "range expected at most 3 arguments, got #{length(args)}"
      end

    if step == 0,
      do: raise(Otera.Error, kind: :value_error, message: "range() arg 3 must not be zero")

    count = max(0, div(stop - start + step - if(step > 0, do: 1, else: -1), step))

    if count > @max_range,
      do:
        raise(Otera.Error,
          kind: :overflow_error,
          message:
            "Range too big. The sandbox blocks ranges larger than MAX_RANGE (#{@max_range})."
        )

    Enum.map(0..(count - 1)//1, &(start + &1 * step))
  end

  defp builtin("dict", args, %Dict{pairs: pairs}) do
    base =
      case args do
        [] -> []
        [%Dict{pairs: base}] -> base
        [items] -> Enum.map(Value.to_list(items), &(&1 |> unpack(2) |> List.to_tuple()))
      end

    Dict.new(base ++ pairs)
  end

  defp builtin("namespace", args, kwargs), do: Namespace.new(builtin("dict", args, kwargs))

  defp range_integer(value) when is_integer(value), do: value
  defp range_integer(value) when is_boolean(value), do: if(value, do: 1, else: 0)
  defp range_integer(%Undefined{} = undefined), do: Undefined.fail(undefined)

  defp range_integer(value),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "'#{Value.type_name(value)}' object cannot be interpreted as an integer"
      )
end
