defmodule Otera.Evaluator do
  @moduledoc """
  Renders the syntax tree of `Otera.Parser` with the semantics of Python Jinja2.

  The evaluator keeps a stack of scopes, like the local variables of the Python functions that Jinja2 compiles. The last scope is the context, with the variables of the render and the top-level assignments. Above it is the root scope of the template. The body of a loop, a macro call, a with block, an autoescape block and the body of a set or filter block run in a new scope, so their assignments do not leak out. `Otera.Scope` gives the names that each scope starts without, and the names that become missing when the scope ends.

  Each scope is a map in `Otera.State`, so a macro reads the variables of the scopes around its definition as they are when it runs, like a Python closure. Namespaces are the one way to change state across scopes.

  A template that extends another renders its root first, which adds its blocks to the chains of blocks of the context, and then the root of the parent with the same context. After the extends tag, the root renders no text and no top-level block, like Jinja2. A block renders the first block of its chain, and `super()` renders the next one. An include renders a template in a new context, and an import renders it as an `Otera.TemplateModule`.

  `break` and `continue` stop the rest of a loop body. As in Jinja2, the `else` block of a loop runs when no iteration reached the end of the body.
  """

  alias Otera.{
    BlockReference,
    Dict,
    Filters,
    Loop,
    Macro,
    Markup,
    Method,
    Methods,
    Namespace,
    State,
    Template,
    TemplateModule,
    TemplateReference,
    Tests,
    Undefined,
    Value
  }

  # `escape` is the autoescape of the code that runs, which escapes its outputs and joins, like the
  # compile-time autoescape of Jinja2. `autoescape` is the autoescape of the eval context at runtime,
  # which decides if macros, set blocks and some filters give Markup. They differ only in a macro
  # that a template calls where the autoescape differs from where it defined the macro.
  #
  # `output_check` is true in the root of a template with an extends tag, whose output stops when
  # `parent` holds the template that it extends and the line of the extends tag. `depth` counts the nested renders and calls, like
  # the Python stack. `options` are the options of the render, for the templates that it loads.
  defstruct frames: [],
            root: nil,
            filters: %{},
            tests: %{},
            globals: %{},
            name: nil,
            escape: false,
            autoescape: false,
            output_check: false,
            parent: nil,
            depth: 0,
            options: []

  @builtins ["range", "dict", "namespace", "cycler", "joiner", "lipsum"]
  @max_range 100_000

  # The recursion limit of Python is 1000 frames. A macro call or a recursive loop takes about five
  # frames, and a template that renders another takes about one.
  @max_depth 1000
  @call_depth 5

  @doc """
  Renders `template` with `variables`, a map with string keys. Raises `Otera.Error`.

  Options: `:filters`, `:tests` and `:globals`, maps from names to Elixir functions or values, and `:autoescape`, a boolean or a function of the template name.
  """
  @spec render(Template.t(), map, keyword) :: String.t()
  def render(template, variables, opts) do
    ctx = %__MODULE__{
      options: opts,
      filters: names(Keyword.get(opts, :filters, %{})),
      tests: names(Keyword.get(opts, :tests, %{})),
      globals:
        Map.new(Keyword.get(opts, :globals, %{}), fn {name, value} ->
          {to_string(name), Value.from_elixir(value)}
        end)
    }

    State.run(fn ->
      template |> render_template(new_context(variables), ctx) |> IO.iodata_to_binary()
    end)
  end

  ## Templates

  # A context is a map in Otera.State with the variables of a render and the top-level assignments,
  # and the chains of blocks and the exported names of that render.
  defp new_context(variables) do
    context = make_ref()
    State.put(context, variables)
    State.put({:exported, context}, MapSet.new())
    context
  end

  # Renders `template` in a new context, and the templates that it extends. The context gets the
  # blocks of the template, and the autoescape of the template name, like an EvalContext of Jinja2.
  defp render_template(template, context, ctx) do
    State.put({:name, context}, template.name)

    State.put(
      {:blocks, context},
      Map.new(template.blocks, fn {name, block} -> {name, [{template, block}]} end)
    )

    render_root(template, %{ctx | frames: [context], autoescape: escape?(ctx, template)})
  end

  defp render_root(template, ctx) do
    ctx = %{
      deeper(ctx, 1)
      | name: template.name,
        escape: escape?(ctx, template),
        output_check: template.extends?,
        parent: nil
    }

    ctx = open(ctx, template.scope, references(template.scope, context(ctx), nil))
    {output, ctx, _signal} = exec_body(template.ast, %{ctx | root: hd(ctx.frames)})

    # The extends tag gives its line to an error before the root of the parent runs, such as the
    # recursion of a template that extends itself.
    case ctx.parent do
      nil ->
        output

      {parent, line} ->
        [output | at(line, ctx, fn -> render_root(parent, %{ctx | frames: [context(ctx)]}) end)]
    end
  end

  defp context(ctx), do: List.last(ctx.frames)

  # The variables `self` and `super`, which the root of a template and a block set when they read them.
  defp references(scope, context, block) do
    self =
      if scope.self,
        do: %{"self" => %TemplateReference{context: context, name: template_name(context)}},
        else: %{}

    case block do
      {name, depth} when scope.super ->
        Map.put(self, "super", block_reference(context, name, depth + 1))

      _ ->
        self
    end
  end

  defp template_name(context), do: State.get({:name, context})

  defp block_reference(context, name, depth) do
    if depth < length(State.get({:blocks, context})[name]),
      do: %BlockReference{context: context, name: name, depth: depth},
      else: %Undefined{
        hint: "there is no parent block called #{Value.repr(name)}.",
        name: "super"
      }
  end

  # Renders the block at `depth` in the chain of blocks `name`, as a function with the context.
  defp render_block(context, name, depth, ctx) do
    {template, {:block, ^name, _scoped, _required, body, _line, scope}} =
      Enum.at(State.get({:blocks, context})[name], depth)

    ctx = %{
      ctx
      | frames: [context],
        name: template.name,
        escape: escape?(ctx, template),
        output_check: false,
        root: nil,
        parent: nil
    }

    {output, _ctx, _signal} =
      exec_body(body, open(ctx, scope, references(scope, context, {name, depth})))

    IO.iodata_to_binary(output)
  end

  # get_template of Jinja2 for extends and imports.
  defp get_template(%Template{} = template, _ctx), do: template
  defp get_template(%Undefined{} = undefined, _ctx), do: Undefined.fail(undefined)
  defp get_template(%Markup{text: name}, ctx), do: get_template(name, ctx)

  defp get_template(name, ctx) when is_binary(name) do
    key = {:template, name}

    case State.get(key) do
      nil ->
        template = Template.load(name, ctx.options)
        State.put(key, template)
        template

      template ->
        template
    end
  end

  defp get_template(name, _ctx) do
    Value.hashable!(name)
    raise Otera.Error, kind: :template_not_found, message: Value.to_str(name)
  end

  # get_or_select_template of Jinja2 for includes: a list of names gives the first template that loads.
  defp select_template(name, ctx)
       when is_binary(name) or is_struct(name, Undefined) or is_struct(name, Markup) or
              is_struct(name, Template),
       do: get_template(name, ctx)

  defp select_template(names, ctx) do
    unless Value.truthy?(names) do
      raise Otera.Error,
        kind: :templates_not_found,
        message: "Tried to select from an empty list of templates."
    end

    names = Value.to_list(names)

    Enum.find_value(names, fn name ->
      try do
        get_template(name, ctx)
      rescue
        error in Otera.Error ->
          if error.kind in [:template_not_found, :undefined_error],
            do: nil,
            else: reraise(error, __STACKTRACE__)
      end
    end) || templates_not_found(names)
  end

  defp templates_not_found(names) do
    names =
      Enum.map_join(names, ", ", fn
        %Undefined{} = undefined -> Undefined.message(undefined)
        name -> Value.to_str(name)
      end)

    raise Otera.Error,
      kind: :templates_not_found,
      message: "none of the templates given were found: #{names}"
  end

  # The variables of the scopes of a template, without the context, for an include or a scoped
  # block, like dump_local_context of Jinja2.
  defp locals(ctx) do
    ctx.frames
    |> Enum.drop(-1)
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn frame, locals ->
      frame = if is_map(frame), do: frame, else: State.get(frame)
      Map.merge(locals, Map.reject(frame, fn {_name, value} -> value in [:unset, :missing] end))
    end)
  end

  # An include or an import with context gets a new context with the variables of the render and
  # the local variables, like new_context(context.get_all(), True, locals) of Jinja2.
  defp included_context(ctx), do: new_context(Map.merge(State.get(context(ctx)), locals(ctx)))

  # A scoped block gets such a context with the blocks of the render, like Context.derived.
  defp derived_context(ctx) do
    context = included_context(ctx)
    State.put({:blocks, context}, State.get({:blocks, context(ctx)}))
    State.put({:name, context}, template_name(context(ctx)))
    context
  end

  # Renders `template` as a module: with the variables of the render, or only with the globals,
  # which Jinja2 renders once for each template.
  defp make_module(template, true, ctx), do: render_module(template, included_context(ctx), ctx)

  defp make_module(template, false, ctx) do
    key = {:module, template.name || template}

    with nil <- State.get(key) do
      module = render_module(template, new_context(%{}), ctx)
      State.put(key, module)
      module
    end
  end

  defp render_module(template, context, ctx) do
    body = template |> render_template(context, ctx) |> IO.iodata_to_binary()
    variables = State.get(context)
    exports = Map.new(State.get({:exported, context}), &{&1, variables[&1]})
    %TemplateModule{name: template.name, body: body, exports: exports}
  end

  defp deeper(ctx, cost) do
    if ctx.depth + cost > @max_depth,
      do: raise(Otera.Error, kind: :recursion_error, message: "maximum recursion depth exceeded")

    %{ctx | depth: ctx.depth + cost}
  end

  defp names(map), do: Map.new(map, fn {name, value} -> {to_string(name), value} end)

  defp escape?(ctx, template),
    do: autoescape?(Keyword.get(ctx.options, :autoescape, false), template.name)

  defp autoescape?(autoescape, name) when is_function(autoescape, 1),
    do: Value.truthy?(autoescape.(name))

  defp autoescape?(autoescape, _name), do: Value.truthy?(autoescape)

  ## Statements

  defp exec_body(nodes, ctx), do: exec_body(nodes, ctx, [])

  defp exec_body([], ctx, acc), do: {acc, ctx, :ok}

  defp exec_body([node | rest], ctx, acc) do
    case exec(node, ctx) do
      {output, ctx, :ok} -> exec_body(rest, ctx, [acc | output])
      {output, ctx, signal} -> {[acc | output], ctx, signal}
    end
  end

  # In a template that extends another, the root renders nothing after the extends tag.
  defp exec(node, %{output_check: true, parent: {%Template{}, _line}} = ctx)
       when elem(node, 0) in [:text, :output],
       do: {[], ctx, :ok}

  defp exec({:text, text}, ctx), do: {text, ctx, :ok}

  defp exec({:output, expr, line}, ctx),
    do: {at(line, ctx, fn -> output(eval(expr, ctx), ctx) end), ctx, :ok}

  defp exec({:extends, expr, line, check_line}, ctx) do
    if ctx.parent do
      at(check_line, ctx, fn ->
        raise Otera.Error, kind: :template_runtime_error, message: "extended multiple times"
      end)
    end

    parent = at(line, ctx, fn -> get_template(eval(expr, ctx), ctx) end)
    blocks = State.get({:blocks, context(ctx)})

    blocks =
      Enum.reduce(parent.blocks, blocks, fn {name, block}, blocks ->
        Map.update(blocks, name, [{parent, block}], &(&1 ++ [{parent, block}]))
      end)

    State.put({:blocks, context(ctx)}, blocks)
    {[], %{ctx | parent: {parent, line}}, :ok}
  end

  # A block at the top level renders only when the template extends no other template.
  defp exec({:block, _name, _scoped?, _required?, _body, _line, _scope}, %{parent: {_, _}} = ctx)
       when hd(ctx.frames) == ctx.root,
       do: {[], ctx, :ok}

  defp exec({:block, name, scoped?, required?, _body, line, _scope}, ctx) do
    output =
      at(line, ctx, fn ->
        if required? and length(State.get({:blocks, context(ctx)})[name]) <= 1 do
          raise Otera.Error,
            kind: :template_runtime_error,
            message: "Required block #{Value.repr(name)} not found"
        end

        context = if scoped?, do: derived_context(ctx), else: context(ctx)
        render_block(context, name, 0, ctx)
      end)

    {output, ctx, :ok}
  end

  defp exec({:include, expr, ignore_missing?, with_context?, line}, ctx) do
    output =
      at(line, ctx, fn ->
        case load_include(eval(expr, ctx), ignore_missing?, ctx) do
          nil -> []
          template when with_context? -> render_template(template, included_context(ctx), ctx)
          template -> make_module(template, false, ctx).body
        end
      end)

    {output, ctx, :ok}
  end

  defp exec({:import, expr, target, with_context?, line}, ctx) do
    module =
      at(line, ctx, fn -> make_module(get_template(eval(expr, ctx), ctx), with_context?, ctx) end)

    ctx = put_var(ctx, target, module)
    unexport(ctx, [target])
    {[], ctx, :ok}
  end

  defp exec({:from_import, expr, names, with_context?, line}, ctx) do
    module =
      at(line, ctx, fn -> make_module(get_template(eval(expr, ctx), ctx), with_context?, ctx) end)

    position = if ctx.name, do: "line #{line} in #{Value.repr(ctx.name)}", else: "line #{line}"

    ctx =
      Enum.reduce(names, ctx, fn {name, alias_name}, ctx ->
        value =
          case module.exports do
            %{^name => value} ->
              value

            _ ->
              %Undefined{
                hint:
                  "the template #{Value.repr(module.name)} (imported on #{position}) does not export the requested name #{Value.repr(name)}",
                name: name
              }
          end

        put_var(ctx, alias_name, value)
      end)

    unexport(ctx, Enum.map(names, &elem(&1, 1)))
    {[], ctx, :ok}
  end

  defp exec({control, _line}, ctx) when control in [:break, :continue], do: {[], ctx, control}

  defp exec({:if, branches, else_body}, ctx) do
    taken =
      Enum.find(branches, fn {test, _body, line} ->
        at(line, ctx, fn -> Value.truthy?(eval(test, ctx)) end)
      end)

    case taken do
      {_test, body, _line} -> exec_body(body, ctx)
      nil -> exec_body(else_body, ctx)
    end
  end

  defp exec({:set, target, expr, line, check_line}, ctx) do
    at(check_line, ctx, fn -> check_namespaces(target, ctx) end)
    {[], at(line, ctx, fn -> assign(target, eval(expr, ctx), ctx) end), :ok}
  end

  defp exec({:set_block, target, filter, body, line, scope}, ctx) do
    value = capture(body, scope, ctx)

    at(line, ctx, fn ->
      value = if filter, do: eval(fill_hole(filter, safe(value, ctx.escape)), ctx), else: value
      value = if ctx.autoescape, do: Markup.new(Value.to_str(value)), else: value
      {[], assign(target, value, ctx), :ok}
    end)
  end

  defp exec({:for, _target, iter, _test, _body, _else, _recursive?, line, _scopes} = node, ctx),
    do: loop(node, at(line, ctx, fn -> eval(iter, ctx) end), ctx, 0)

  defp exec({:macro, name, params, body, special_names, line, scope}, ctx) do
    macro = %Macro{
      name: name,
      params: params,
      body: body,
      special_names: special_names,
      frames: ctx.frames,
      scope: scope,
      line: line,
      escape: ctx.escape,
      template: ctx.name
    }

    {[], put_var(ctx, name, macro), :ok}
  end

  defp exec(
         {:call_block, {:call, callee, args, kwargs, _call_line}, params, body, special_names,
          line, scope},
         ctx
       ) do
    caller = %Macro{
      name: nil,
      params: params,
      body: body,
      special_names: special_names,
      frames: ctx.frames,
      scope: scope,
      line: line,
      escape: ctx.escape,
      template: ctx.name
    }

    at(line, ctx, fn ->
      {args, %Dict{} = kwargs} = eval_args(args, kwargs, ctx)
      value = call_value(eval(callee, ctx), args, Dict.put(kwargs, "caller", caller), ctx)
      {Value.to_str(value), ctx, :ok}
    end)
  end

  defp exec({:filter_block, filter, body, line, scope}, ctx) do
    value = safe(capture(body, scope, ctx), ctx.escape)
    {at(line, ctx, fn -> Value.to_str(eval(fill_hole(filter, value), ctx)) end), ctx, :ok}
  end

  # Like a with block, the autoescape tag opens a scope, which Jinja2 evaluates the value in.
  defp exec({:autoescape, expr, body, line, scope}, ctx) do
    inner = open(ctx, scope, %{})
    autoescape = at(line, ctx, fn -> Value.truthy?(eval(expr, inner)) end)

    {output, _inner, signal} =
      exec_body(body, %{inner | escape: autoescape, autoescape: autoescape})

    close(inner, scope)
    {output, ctx, signal}
  end

  defp exec({:with, assignments, body, line, scope}, ctx) do
    frame =
      at(line, ctx, fn ->
        Enum.reduce(assignments, %{}, fn {target, expr}, frame ->
          Map.merge(frame, bind(target, eval(expr, ctx)))
        end)
      end)

    inner = open(ctx, scope, frame)
    {output, _inner, signal} = exec_body(body, inner)
    close(inner, scope)
    {output, ctx, signal}
  end

  # The generation block of transformers is a call block, so its body runs in a function scope.
  defp exec({:generation, body, scope}, ctx) do
    {output, _inner, _signal} = exec_body(body, open(ctx, scope, %{}))
    {IO.iodata_to_binary(output), ctx, :ok}
  end

  # Gives a runtime error the line and template of the code that raised it, like the traceback of
  # Jinja2. The innermost code sets the position first, so a macro call keeps the line in the macro.
  defp at(line, ctx, fun) do
    fun.()
  rescue
    error in Otera.Error ->
      error = if error.line, do: error, else: %{error | line: line, name: ctx.name}
      reraise error, __STACKTRACE__
  end

  # Includes catch only a missing template, and their template can be a list of names.
  defp load_include(value, ignore_missing?, ctx) do
    select_template(value, ctx)
  rescue
    error in Otera.Error ->
      if ignore_missing? and error.kind in [:template_not_found, :templates_not_found],
        do: nil,
        else: reraise(error, __STACKTRACE__)
  end

  defp capture(body, scope, ctx) do
    inner = open(ctx, scope, %{})
    {output, _inner, _signal} = exec_body(body, inner)
    close(inner, scope)
    IO.iodata_to_binary(output)
  end

  defp safe(text, true), do: Markup.new(text)
  defp safe(text, false), do: text

  # Like the output of Jinja2: with autoescape, escape(value), and else str(value).
  defp output(value, %{escape: true}), do: Markup.escape(value).text
  defp output(value, _ctx), do: Value.to_str(value)

  defp fill_hole({:filter, name, nil, args, kwargs, line}, value),
    do: {:filter, name, {:const, value}, args, kwargs, line}

  defp fill_hole({:filter, name, inner, args, kwargs, line}, value),
    do: {:filter, name, fill_hole(inner, value), args, kwargs, line}

  defp loop(
         {:for, target, _iter, test, body, else_body, recursive?, line, scopes} = node,
         iterable,
         ctx,
         depth0
       ) do
    {body_scope, else_scope} = scopes
    all = at(line, ctx, fn -> Value.to_list(iterable) end)
    indexed = Enum.with_index(all)

    indexed =
      case test do
        {test, test_line} ->
          at(test_line, ctx, fn ->
            Enum.filter(indexed, fn {item, _} ->
              Value.truthy?(eval(test, push(ctx, bind(target, item))))
            end)
          end)

        nil ->
          indexed
      end

    items = indexed |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
    recurse = if recursive?, do: {node, ctx}
    ref = make_ref()

    # One scope for all iterations, which each iteration starts again, like the body of a Python loop.
    inner = open(ctx, body_scope, %{})

    {output, completed?, rest} =
      Enum.reduce_while(0..(tuple_size(items) - 1)//1, {[], false, []}, fn index,
                                                                           {acc, completed?, _} ->
        loop = %Loop{ref: ref, items: items, index0: index, depth0: depth0, recurse: recurse}

        frame = at(line, ctx, fn -> bind(target, elem(items, index)) end)
        # Like Jinja2, the scope has the loop variable only when the body reads it.
        frame =
          if body_scope.exit["loop"] == :missing, do: Map.put(frame, "loop", loop), else: frame

        restart(inner, body_scope, frame)
        {output, _inner, signal} = exec_body(body, inner)

        case signal do
          :ok ->
            {:cont, {[acc | output], true, []}}

          :continue ->
            {:cont, {[acc | output], completed?, []}}

          :break ->
            rest = unreached(all, indexed, index, Loop.peeked(ref, index))
            {:halt, {[acc | output], completed?, rest}}
        end
      end)

    if is_struct(iterable, Otera.Iterable), do: Otera.Iterable.give_back(iterable, rest)

    # A recursive loop without else is a Python function, which keeps its scope.
    unless recursive? and else_body == [], do: close(inner, body_scope)

    if completed? or else_body == [] do
      {output, ctx, :ok}
    else
      inner = open(ctx, else_scope, %{})
      {else_output, _inner, signal} = exec_body(else_body, inner)
      close(inner, else_scope)
      {[output | else_output], ctx, signal}
    end
  end

  # The items of an iterator that a loop did not take when it broke at `index`: the items after
  # that item, or after the next item when the loop looked ahead.
  defp unreached(_all, _indexed, _index, :all), do: []

  defp unreached(all, indexed, index, peeked) do
    case Enum.at(indexed, index + peeked) do
      {_item, position} -> Enum.drop(all, position + 1)
      nil -> []
    end
  end

  defp assign({:ns_ref, name, attr}, value, ctx) do
    Namespace.put(lookup(ctx, name), attr, value)
    ctx
  end

  defp assign({:tuple, targets}, value, ctx) do
    targets
    |> Enum.zip(unpack(value, length(targets)))
    |> Enum.reduce(ctx, fn {target, item}, ctx -> assign(target, item, ctx) end)
  end

  defp assign({:name, name}, value, ctx), do: put_var(ctx, name, value)

  # Like Jinja2, a set checks that the targets of its namespace assignments are namespaces before it
  # evaluates the value.
  defp check_namespaces({:ns_ref, name, _attr}, ctx) do
    unless is_struct(lookup(ctx, name), Namespace) do
      raise Otera.Error,
        kind: :template_runtime_error,
        message: "cannot assign attribute on non-namespace object"
    end
  end

  defp check_namespaces({:tuple, targets}, ctx),
    do: Enum.each(targets, &check_namespaces(&1, ctx))

  defp check_namespaces(_target, _ctx), do: :ok

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

  # A frame is a reference to the map of a scope in Otera.State, or a plain map for the scope of
  # a loop test, which no macro can see.
  defp push(ctx, frame), do: %{ctx | frames: [frame | ctx.frames]}

  defp open(ctx, scope, bindings) do
    ref = make_ref()
    restart(%{ctx | frames: [ref]}, scope, bindings)
    push(ctx, ref)
  end

  defp restart(%{frames: [ref | _]}, scope, bindings),
    do: State.put(ref, Enum.reduce(scope.unset, bindings, &Map.put_new(&2, &1, :unset)))

  defp close(%{frames: [ref | _]}, scope),
    do: State.put(ref, Map.merge(State.get(ref), scope.exit))

  # An assignment in the root scope also sets the variable of the context, like Jinja2.
  defp put_var(%{frames: [ref | _]} = ctx, name, value) do
    State.put(ref, Map.put(State.get(ref), name, value))

    if ref == ctx.root do
      context = context(ctx)
      State.put(context, Map.put(State.get(context), name, value))

      unless String.starts_with?(name, "_"),
        do: State.put({:exported, context}, MapSet.put(State.get({:exported, context}), name))
    end

    ctx
  end

  # Imported names are not exported, like Jinja2.
  defp unexport(ctx, names) do
    key = {:exported, context(ctx)}
    State.put(key, MapSet.difference(State.get(key), MapSet.new(names)))
  end

  defp lookup(ctx, name) do
    case find_var(ctx.frames, name) do
      {:ok, :unset} -> %Undefined{name: name}
      {:ok, value} -> value
      :error -> global(ctx, name)
    end
  end

  defp find_var([], _name), do: :error

  defp find_var([frame | rest], name) do
    case if(is_map(frame), do: frame, else: State.get(frame)) do
      %{^name => value} -> {:ok, value}
      _ -> find_var(rest, name)
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

  defp eval({:cond_undefined, line}, ctx) do
    position = if ctx.name, do: "line #{line} in #{Value.repr(ctx.name)}", else: "line #{line}"

    %Undefined{
      hint:
        "the inline if-expression on #{position} evaluated to false and no else section was defined."
    }
  end

  defp eval({:name, name}, ctx), do: lookup(ctx, name)
  defp eval({:list, items}, ctx), do: Enum.map(items, &eval(&1, ctx))
  defp eval({:tuple, items}, ctx), do: items |> Enum.map(&eval(&1, ctx)) |> List.to_tuple()

  defp eval({:dict, pairs}, ctx) do
    pairs
    |> Enum.map(fn {key, value} -> {eval(key, ctx), eval(value, ctx)} end)
    |> tap(&Enum.each(&1, fn {key, _value} -> Value.hashable!(key) end))
    |> Dict.new()
  end

  defp eval({:getattr, expr, name, _line}, ctx), do: Value.getattr(eval(expr, ctx), name)

  defp eval({:getitem, expr, {:slice, start, stop, step}, _line}, ctx),
    do:
      Value.slice(
        eval(expr, ctx),
        eval_optional(start, ctx),
        eval_optional(stop, ctx),
        eval_optional(step, ctx)
      )

  defp eval({:getitem, expr, key, _line}, ctx), do: Value.getitem(eval(expr, ctx), eval(key, ctx))
  defp eval({:not, expr}, ctx), do: not Value.truthy?(eval(expr, ctx))
  defp eval({:not, test, _line}, ctx), do: not Value.truthy?(eval(test, ctx))
  defp eval({:neg, expr}, ctx), do: Value.unary_op(:neg, eval(expr, ctx))
  defp eval({:pos, expr}, ctx), do: Value.unary_op(:pos, eval(expr, ctx))

  defp eval({:and, left, right, _line}, ctx) do
    left = eval(left, ctx)
    if Value.truthy?(left), do: eval(right, ctx), else: left
  end

  defp eval({:or, left, right, _line}, ctx) do
    left = eval(left, ctx)
    if Value.truthy?(left), do: left, else: eval(right, ctx)
  end

  defp eval({:binop, op, left, right, _line}, ctx),
    do: Value.binary_op(op, eval(left, ctx), eval(right, ctx))

  defp eval({:concat, exprs}, ctx), do: concat(Enum.map(exprs, &eval(&1, ctx)), ctx.escape)
  defp eval({:compare, expr, ops, _line}, ctx), do: compare(eval(expr, ctx), ops, ctx)

  defp eval({:cond, test, then_expr, else_expr, _line}, ctx) do
    if Value.truthy?(eval(test, ctx)), do: eval(then_expr, ctx), else: eval(else_expr, ctx)
  end

  defp eval({:call, callee, args, kwargs, _line}, ctx) do
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

  # markup_join of Jinja2: with autoescape, a Markup part makes the result a Markup, and the
  # plain parts are escaped. Else str_join.
  defp concat(values, true) do
    if Enum.any?(values, &is_struct(&1, Markup)),
      do: Methods.call(Markup.new(""), "join", [Enum.map(values, &Markup.soft_str/1)], %Dict{}),
      else: Enum.map_join(values, &Value.to_str/1)
  end

  defp concat(values, false), do: Enum.map_join(values, &Value.to_str/1)

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

  defp call_value(%Loop{recurse: {node, loop_ctx}, depth0: depth0}, [iterable], _kwargs, ctx) do
    loop_ctx = %{loop_ctx | depth: deeper(ctx, @call_depth).depth}
    {output, _ctx, _signal} = loop(node, iterable, loop_ctx, depth0 + 1)
    safe(IO.iodata_to_binary(output), loop_ctx.escape)
  end

  defp call_value(%BlockReference{} = block, args, kwargs, ctx) do
    Methods.bind(args, kwargs, [], "BlockReference.__call__")
    safe(render_block(block.context, block.name, block.depth, ctx), ctx.autoescape)
  end

  defp call_value(%Loop{}, _args, _kwargs, _ctx),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "The loop must have the 'recursive' marker to be called recursively."
      )

  defp call_value(%Undefined{} = undefined, _args, _kwargs, _ctx), do: Undefined.fail(undefined)

  defp call_value(%Otera.Joiner{} = joiner, args, kwargs, _ctx) do
    Methods.bind(args, kwargs, [], "Joiner.__call__")
    Otera.Joiner.call(joiner)
  end

  defp call_value(fun, args, kwargs, _ctx)
       when is_function(fun) or is_struct(fun, Otera.Function),
       do: call_function(fun, args, kwargs)

  defp call_value(value, _args, _kwargs, _ctx),
    do:
      raise(Otera.Error,
        kind: :type_error,
        message: "'#{Value.type_name(value)}' object is not callable"
      )

  defp call_function(%Otera.Function{} = function, args, kwargs) do
    values = Methods.bind(args, kwargs, function.params, function.name)
    function.fun |> apply(values) |> Value.from_elixir()
  end

  # A plain Elixir function takes positional arguments only.
  defp call_function(fun, args, %Dict{pairs: pairs}) do
    {:arity, arity} = Function.info(fun, :arity)

    cond do
      pairs != [] ->
        {name, _} = hd(pairs)

        raise Otera.Error,
          kind: :type_error,
          message: "function got an unexpected keyword argument #{Value.repr(name)}"

      arity != length(args) ->
        raise Otera.Error,
          kind: :type_error,
          message: "function takes #{arity} positional arguments but #{length(args)} were given"

      true ->
        fun |> apply(args) |> Value.from_elixir()
    end
  end

  # The body escapes like the place that defines the macro, and the result is a Markup when the
  # place that calls it has autoescape, like Macro.__call__ of Jinja2.
  defp call_macro(macro, args, kwargs, ctx) do
    {positional, extra} = Enum.split(args, length(macro.params))
    ctx = deeper(ctx, @call_depth)

    macro_ctx =
      open(
        %{
          ctx
          | frames: macro.frames,
            escape: macro.escape,
            name: macro.template,
            output_check: false
        },
        macro.scope,
        %{}
      )

    {macro_ctx, kwargs} =
      at(macro.line, macro_ctx, fn -> bind_params(macro_ctx, macro.params, positional, kwargs) end)

    {macro_ctx, kwargs} = bind_caller(macro_ctx, macro, kwargs)
    macro_ctx = macro_ctx |> bind_kwargs(macro, kwargs) |> bind_varargs(macro, extra)
    {output, _ctx, _signal} = exec_body(macro.body, macro_ctx)
    safe(IO.iodata_to_binary(output), ctx.autoescape)
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

    range = %Otera.Range{start: start, stop: stop, step: step}

    if Otera.Range.size(range) > @max_range,
      do:
        raise(Otera.Error,
          kind: :overflow_error,
          message:
            "Range too big. The sandbox blocks ranges larger than MAX_RANGE (#{@max_range})."
        )

    range
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

  defp builtin("cycler", args, kwargs) do
    Methods.bind([], kwargs, [], "Cycler.__init__")
    Otera.Cycler.new(args)
  end

  defp builtin("joiner", args, kwargs) do
    [sep] = Methods.bind(args, kwargs, [{"sep", ", "}], "Joiner.__init__")
    Otera.Joiner.new(sep)
  end

  defp builtin("lipsum", args, kwargs) do
    params = [{"n", 5}, {"html", true}, {"min", 20}, {"max", 100}]
    [count, html, min, max] = Methods.bind(args, kwargs, params, "generate_lorem_ipsum")
    Otera.Lipsum.generate(count, Value.truthy?(html), min, max)
  end

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
