defmodule Otera.Parser do
  @moduledoc """
  Parses the tokens of `Otera.Lexer` into an abstract syntax tree, with the grammar of the Python Jinja2 parser.

  The tree is a list of nodes. Nodes are tuples, so that the evaluator can pattern match on them.

  Statements:

    * `{:text, string}` and `{:output, expr, line}`
    * `{:if, [{test, body, line}], else_body}`
    * `{:for, target, iter, {test, line} | nil, body, else_body, recursive?, line, scopes}`
    * `{:set, target, expr, line, check_line}` and `{:set_block, target, filter_or_nil, body, line, scope}`
    * `{:macro, name, params, body, special_names, line, scope}` and `{:call_block, call, params, body, special_names, line, scope}`
    * `{:filter_block, filter, body, line, scope}`, `{:with, [{target, expr}], body, line, scope}` and `{:generation, body, scope}`
    * `{:autoescape, expr, body, line, scope}`
    * `{:extends, expr, line, check_line}` and `{:block, name, scoped?, required?, body, line, scope}`
    * `{:include, expr, ignore_missing?, with_context?, line}`, `{:import, expr, target, with_context?, line}` and `{:from_import, expr, [{name, alias}], with_context?, line}`
    * `{:break, line}` and `{:continue, line}`

  Expressions:

    * `{:const, value}`, `{:name, name}`, `{:list, items}`, `{:tuple, items}` and `{:dict, [{key, value}]}`
    * `{:getattr, expr, name, line}`, `{:getitem, expr, key, line}` and `{:slice, start, stop, step}` as a key
    * `{:call, callee, args, kwargs, line}`, `{:filter, name, expr, args, kwargs, line}` and `{:test, name, expr, args, kwargs, line}`, where `args` has expressions and `{:unpack, expr}` for `*expr`, and `kwargs` has `{name, expr}` and `{:unpack, expr}` for `**expr`
    * `{:not, expr}`, `{:not, test, line}` for `is not`, `{:neg, expr}`, `{:pos, expr}`, `{:and, left, right, line}` and `{:or, left, right, line}`
    * `{:binop, op, left, right, line}` with op `:add`, `:sub`, `:mul`, `:div`, `:floordiv`, `:mod` or `:pow`
    * `{:concat, exprs}`, `{:compare, expr, [{op, expr}], line}` and `{:cond, test, then, else, line}`
    * `{:ns_ref, name, attr}` as an assignment target
    * `{:cond_undefined, line}`, the undefined value of an inline `if` without `else`

  A node that opens a scope has `nil` as its scope, which `Otera.Scope.annotate/1` fills in. A loop has the scopes of its body and of its else block.

  The lines are the lines that Jinja2 gives to its nodes. The evaluator gives them to the runtime errors, like the template traceback of Jinja2. The line of a statement is the line of its tag, and the line of an output is the line of the outermost node of its expression. The `check_line` of a set and of an extends tag, and the `line` of a with block and of an autoescape block are the line of the code before them, because Jinja2 compiles the namespace check and the assignments without a line of their own.

  A filter of a filter block or a set block has `nil` as its innermost expression. An inline `if` without `else` gets `{:cond_undefined, line}` as its `else`. `params` of a macro is a list of `{name, default_or_nil}`, and `special_names` lists which of `caller`, `varargs` and `kwargs` the body uses.

  As in Jinja2, an unknown filter or test is a syntax error, except inside an `if` block or an inline `if`, where it fails only when the template uses it.
  """

  alias Otera.SyntaxError

  @compare_ops %{"==" => :eq, "!=" => :ne, "<" => :lt, "<=" => :lteq, ">" => :gt, ">=" => :gteq}
  @math1_ops %{"+" => :add, "-" => :sub}
  @math2_ops %{"*" => :mul, "/" => :div, "//" => :floordiv, "%" => :mod}
  @special_names ["caller", "varargs", "kwargs"]
  # The frame of the code inside a loop, a macro, a block and the other tags that open a scope.
  @inner %{soft: false, toplevel: false}

  @doc """
  Returns the syntax tree of `tokens`. Raises `Otera.SyntaxError`.

  Options: `:filters` and `:tests`, the names of the custom filters and tests besides the builtin ones.
  """
  @spec parse([Otera.Lexer.token()], keyword) :: [tuple | atom]
  def parse(tokens, opts \\ []) do
    {body, _eof} = subparse(tokens, nil, %{tags: [], ends: [], loop: false})
    check_blocks(body)
    known = %{filter: Keyword.get(opts, :filters, []), test: Keyword.get(opts, :tests, [])}
    check_names(body, known, %{soft: false, toplevel: true})
    # Jinja2 compiles the blocks after the root of the template, each as a function.
    for {:block, _, _, _, block_body, _, _} <- blocks(body),
        do: check_names(block_body, known, @inner)

    {body, _last} = fill_lines(body, 1)
    body
  end

  @doc """
  Returns true if `ast` has an extends tag.
  """
  @spec extends?(list) :: boolean
  def extends?({:extends, _expr, _line, _check_line}), do: true
  def extends?(node) when is_tuple(node), do: extends?(Tuple.to_list(node))
  def extends?(nodes) when is_list(nodes), do: Enum.any?(nodes, &extends?/1)
  def extends?(_leaf), do: false

  @doc """
  Returns the blocks of `ast`, also the blocks inside other blocks, in the order of the template.
  """
  @spec blocks(list) :: [tuple]
  def blocks(ast), do: ast |> collect_blocks([]) |> Enum.reverse()

  defp collect_blocks({:block, _name, _scoped, _required, body, _line, _scope} = block, acc),
    do: collect_blocks(body, [block | acc])

  defp collect_blocks(nodes, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &collect_blocks/2)

  defp collect_blocks(node, acc) when is_tuple(node), do: collect_blocks(Tuple.to_list(node), acc)
  defp collect_blocks(_leaf, acc), do: acc

  # Like the compiler of Jinja2, which finds the blocks before it compiles the template.
  defp check_blocks(body) do
    Enum.reduce(blocks(body), MapSet.new(), fn {:block, name, _, _, _, line, _}, seen ->
      if MapSet.member?(seen, name), do: fail("block #{repr(name)} defined twice", line)
      MapSet.put(seen, name)
    end)
  end

  # Jinja2 maps each line of the compiled Python code to the template line of the last node that
  # it compiled before that code. Most statements and outputs set the line, but the namespace check
  # of a set and the assignments of a with block have no line of their own, so their errors give
  # the line of the code before them. `last` is that line, in the order of the compiled code.
  defp fill_lines(nodes, last), do: Enum.map_reduce(nodes, last, &fill_line/2)

  defp fill_line({:output, _expr, line} = node, _last), do: {node, line}

  defp fill_line({control, line} = node, _last) when control in [:break, :continue],
    do: {node, line}

  defp fill_line({:set, target, expr, line, nil}, last),
    do: {{:set, target, expr, line, last}, line}

  defp fill_line({:if, branches, else_body}, last) do
    {branches, last} =
      Enum.map_reduce(branches, last, fn {test, body, line}, _last ->
        {body, last} = fill_lines(body, line)
        {{test, body, line}, last}
      end)

    {else_body, last} = fill_lines(else_body, last)
    {{:if, branches, else_body}, last}
  end

  defp fill_line({:for, target, iter, test, body, else_body, recursive?, line, nil}, _last) do
    {body, last} = fill_lines(body, line)
    {else_body, last} = fill_lines(else_body, last)
    # A recursive loop is a function, and the code that calls it comes after it.
    last = if recursive?, do: line, else: last
    {{:for, target, iter, test, body, else_body, recursive?, line, nil}, last}
  end

  defp fill_line({:set_block, target, filter, body, line, nil}, last) do
    {body, _last} = fill_lines(body, last)
    {{:set_block, target, filter, body, line, nil}, line}
  end

  defp fill_line({:macro, name, params, body, special_names, line, nil}, _last) do
    {body, last} = fill_lines(body, line)
    {{:macro, name, params, body, special_names, line, nil}, last}
  end

  defp fill_line({:call_block, call, params, body, special_names, line, nil}, _last) do
    {body, _last} = fill_lines(body, line)
    {{:call_block, call, params, body, special_names, line, nil}, line}
  end

  defp fill_line({:filter_block, filter, body, line, nil}, last) do
    {body, _last} = fill_lines(body, last)
    {{:filter_block, filter, body, line, nil}, line}
  end

  defp fill_line({:with, assignments, body, nil, nil}, last) do
    {body, body_last} = fill_lines(body, last)
    {{:with, assignments, body, last, nil}, body_last}
  end

  defp fill_line({:autoescape, expr, body, nil, nil}, last) do
    {body, body_last} = fill_lines(body, last)
    {{:autoescape, expr, body, last, nil}, body_last}
  end

  defp fill_line({:generation, body, nil}, last) do
    {body, last} = fill_lines(body, last)
    {{:generation, body, nil}, last}
  end

  defp fill_line({:extends, expr, line, nil}, last), do: {{:extends, expr, line, last}, line}

  # A block is a function of its own, and the code that renders it has the line of the block.
  defp fill_line({:block, name, scoped?, required?, body, line, nil}, _last) do
    {body, _last} = fill_lines(body, line)
    {{:block, name, scoped?, required?, body, line, nil}, line}
  end

  defp fill_line({tag, _expr, _a, _b, line} = node, _last)
       when tag in [:include, :import, :from_import],
       do: {node, line}

  defp fill_line(node, last), do: {node, last}

  # Jinja2 resolves filters and tests at compile time, but not in the soft frames of if blocks and
  # inline ifs. `frame` also tells if the code is at the top level, where an extends tag can be: the
  # root of the template and its if blocks.

  defp check_names({:if, branches, else_body}, known, frame) do
    check_names(branches, known, %{frame | soft: true})
    check_names(else_body, known, %{frame | soft: true})
  end

  defp check_names(
         {:for, _target, iter, test, body, else_body, _recursive, _line, _scope},
         known,
         frame
       ) do
    check_names(iter, known, frame)
    check_names([test, body, else_body], known, @inner)
  end

  defp check_names({:macro, _name, params, body, _special, _line, _scope}, known, _frame),
    do: check_names([params, body], known, @inner)

  defp check_names({:call_block, call, params, body, _special, _line, _scope}, known, frame) do
    check_names(call, known, frame)
    check_names([params, body], known, @inner)
  end

  defp check_names({:with, assignments, body, _line, _scope}, known, frame) do
    check_names(assignments, known, frame)
    check_names(body, known, @inner)
  end

  defp check_names({:set_block, _target, filter, body, _line, _scope}, known, _frame),
    do: check_names([filter, body], known, @inner)

  defp check_names({:filter_block, filter, body, _line, _scope}, known, _frame),
    do: check_names([filter, body], known, @inner)

  defp check_names({:generation, body, _scope}, known, _frame),
    do: check_names(body, known, @inner)

  defp check_names({:autoescape, expr, body, _line, _scope}, known, _frame),
    do: check_names([expr, body], known, @inner)

  defp check_names({:block, _name, _scoped, _required, _body, _line, _scope}, _known, _frame),
    do: :ok

  defp check_names({:extends, expr, line, _check_line}, known, frame) do
    unless frame.toplevel, do: fail("cannot use extend from a non top-level scope", line)
    check_names(expr, known, frame)
  end

  defp check_names({:cond, test, then_expr, else_expr, _line}, known, frame),
    do: check_names([test, then_expr, else_expr], known, %{frame | soft: true})

  defp check_names({type, name, expr, args, kwargs, line}, known, frame)
       when type in [:filter, :test] do
    builtin? =
      if type == :filter, do: Otera.Filters.builtin?(name), else: Otera.Tests.builtin?(name)

    unless frame.soft or builtin? or name in known[type] do
      fail("No #{type} named #{repr(name)}.", line)
    end

    check_names([expr, args, kwargs], known, frame)
  end

  defp check_names(node, known, frame) when is_tuple(node),
    do: check_names(Tuple.to_list(node), known, frame)

  defp check_names(nodes, known, frame) when is_list(nodes),
    do: Enum.each(nodes, &check_names(&1, known, frame))

  defp check_names(_leaf, _known, _frame), do: :ok

  ## Statements

  defp subparse(tokens, ends, ctx) do
    ctx = if ends, do: %{ctx | ends: [ends | ctx.ends]}, else: ctx
    subparse(tokens, ends, ctx, [])
  end

  defp subparse([{:data, text, _} | rest], ends, ctx, acc),
    do: subparse(rest, ends, ctx, [{:text, text} | acc])

  defp subparse([{:variable_begin, _, _} | [token | _] = rest], ends, ctx, acc) do
    {expr, rest} = parse_tuple(rest, with_condexpr: true)
    rest = expect(rest, :variable_end)
    subparse(rest, ends, ctx, [{:output, expr, debug_line(expr, token)} | acc])
  end

  defp subparse([{:block_begin, _, _} | rest], ends, ctx, acc) do
    case rest do
      [{:name, name, _} | _] when is_list(ends) and is_binary(name) ->
        if name in ends, do: {Enum.reverse(acc), rest}, else: statement(rest, ends, ctx, acc)

      _ ->
        statement(rest, ends, ctx, acc)
    end
  end

  defp subparse([{:eof, _, _} | _] = tokens, nil, _ctx, acc), do: {Enum.reverse(acc), tokens}
  defp subparse([{:eof, _, line} | _], _ends, ctx, _acc), do: fail_unexpected_tag(nil, ctx, line)

  defp statement(tokens, ends, ctx, acc) do
    {nodes, rest} = parse_statement(tokens, ctx)
    rest = expect(rest, :block_end)
    subparse(rest, ends, ctx, Enum.reverse(List.wrap(nodes), acc))
  end

  defp parse_statement([{:name, tag, line} | rest], ctx),
    do: parse_tag(tag, rest, %{ctx | tags: [tag | ctx.tags]}, line)

  defp parse_statement([token | _], _ctx), do: fail("tag name expected", line(token))

  defp parse_tag("if", rest, ctx, line), do: parse_if(rest, ctx, [], line)
  defp parse_tag("for", rest, ctx, line), do: parse_for(rest, ctx, line)
  defp parse_tag("set", rest, ctx, line), do: parse_set(rest, ctx, line)
  defp parse_tag("macro", rest, ctx, line), do: parse_macro(rest, ctx, line)
  defp parse_tag("call", rest, ctx, line), do: parse_call_block(rest, ctx, line)
  defp parse_tag("filter", rest, ctx, line), do: parse_filter_block(rest, ctx, line)
  defp parse_tag("with", rest, ctx, _line), do: parse_with(rest, ctx)
  defp parse_tag("print", rest, _ctx, _line), do: parse_print(rest)
  defp parse_tag("autoescape", rest, ctx, _line), do: parse_autoescape(rest, ctx)
  defp parse_tag("generation", rest, ctx, _line), do: parse_generation(rest, ctx)

  defp parse_tag(control, rest, ctx, line) when control in ["break", "continue"],
    do: loop_control(control, rest, ctx, line)

  defp parse_tag("extends", rest, _ctx, line) do
    {expr, rest} = parse_expression(rest)
    {{:extends, expr, line, nil}, rest}
  end

  defp parse_tag("block", rest, ctx, line), do: parse_block(rest, ctx, line)

  defp parse_tag("include", rest, _ctx, line) do
    {expr, rest} = parse_expression(rest)

    {ignore_missing?, rest} =
      case rest do
        [{:name, "ignore", _}, {:name, "missing", _} | rest] -> {true, rest}
        rest -> {false, rest}
      end

    {with_context?, rest} = parse_import_context(rest, true)
    {{:include, expr, ignore_missing?, with_context?, line}, rest}
  end

  defp parse_tag("import", rest, _ctx, line) do
    {expr, rest} = parse_expression(rest)
    rest = expect(rest, :name, "as")
    {{:name, target}, rest} = parse_assign_target(rest, name_only: true)
    {with_context?, rest} = parse_import_context(rest, false)
    {{:import, expr, target, with_context?, line}, rest}
  end

  defp parse_tag("from", rest, _ctx, line) do
    {expr, rest} = parse_expression(rest)
    rest = expect(rest, :name, "import")
    {names, with_context?, rest} = parse_import_names(rest, [])
    {{:from_import, expr, names, with_context?, line}, rest}
  end

  defp parse_tag(tag, _rest, ctx, line),
    do: fail_unexpected_tag(tag, %{ctx | tags: tl(ctx.tags)}, line)

  defp loop_control(control, rest, %{loop: true}, line),
    do: {{String.to_existing_atom(control), line}, rest}

  defp loop_control("break", _rest, _ctx, line), do: fail("'break' outside loop", line)

  defp loop_control("continue", _rest, _ctx, line),
    do: fail("'continue' not properly in loop", line)

  defp parse_block(tokens, ctx, line) do
    {name, rest} =
      case tokens do
        [{:name, name, _} | rest] -> {name, rest}
        tokens -> expect(tokens, :name)
      end

    {scoped?, rest} = skip_name(rest, "scoped")
    {required?, rest} = skip_name(rest, "required")

    if match?([{:operator, "-", _} | _], rest),
      do:
        fail(
          "Block names in Jinja have to be valid Python identifiers and may not contain hyphens, use an underscore instead.",
          line(hd(rest))
        )

    {body, [token | _] = rest} = parse_statements(rest, ["endblock"], %{ctx | loop: false}, true)

    blank? =
      Enum.all?(body, &match?({:text, _}, &1)) and Enum.all?(body, &whitespace?(elem(&1, 1)))

    if required? and not blank?,
      do: fail("Required blocks can only contain comments or whitespace", line(token))

    {_skipped, rest} = skip_name(rest, name)
    {{:block, name, scoped?, required?, body, line, nil}, rest}
  end

  defp whitespace?(text), do: text != "" and Otera.Value.strip(text, nil, :both) == ""

  defp skip_name([{:name, name, _} | rest], name), do: {true, rest}
  defp skip_name(rest, _name), do: {false, rest}

  defp parse_import_context([{:name, word, _}, {:name, "context", _} | rest], _default)
       when word in ["with", "without"],
       do: {word == "with", rest}

  defp parse_import_context(rest, default), do: {default, rest}

  # The names of a from import, like parse_from of Jinja2: `a`, `a as b`, and a context at the end.
  defp parse_import_names(tokens, names) do
    tokens = if names == [], do: tokens, else: expect(tokens, :operator, ",")

    case tokens do
      [{:name, word, _}, {:name, "context", _} | _] when word in ["with", "without"] ->
        {with_context?, rest} = parse_import_context(tokens, false)
        {Enum.reverse(names), with_context?, rest}

      [{:name, _, line} | _] ->
        {{:name, name}, rest} = parse_assign_target(tokens, name_only: true)

        if String.starts_with?(name, "_"),
          do: fail("names starting with an underline can not be imported", line)

        {alias_name, rest} =
          case rest do
            [{:name, "as", _} | rest] ->
              {{:name, alias_name}, rest} = parse_assign_target(rest, name_only: true)
              {alias_name, rest}

            rest ->
              {name, rest}
          end

        names = [{name, alias_name} | names]

        case rest do
          [{:operator, ",", _} | _] ->
            parse_import_names(rest, names)

          rest ->
            {with_context?, rest} = parse_import_context(rest, false)
            {Enum.reverse(names), with_context?, rest}
        end

      tokens ->
        expect(tokens, :name)
    end
  end

  defp parse_statements(tokens, ends, ctx, drop_needle? \\ false) do
    tokens = skip_if(tokens, :operator, ":")
    tokens = expect(tokens, :block_end)
    {body, rest} = subparse(tokens, ends, ctx)
    {body, if(drop_needle?, do: tl(rest), else: rest)}
  end

  defp parse_if(tokens, ctx, branches, line) do
    {test, rest} = parse_tuple(tokens, with_condexpr: false)
    {body, rest} = parse_statements(rest, ["elif", "else", "endif"], ctx)
    branches = [{test, body, line} | branches]

    case rest do
      # Jinja2 gives an elif the line of the token after the tag name.
      [{:name, "elif", _}, next | _] = [_ | rest] ->
        parse_if(rest, ctx, branches, line(next))

      [{:name, "else", _} | rest] ->
        {else_body, rest} = parse_statements(rest, ["endif"], ctx, true)
        {{:if, Enum.reverse(branches), else_body}, rest}

      [{:name, "endif", _} | rest] ->
        {{:if, Enum.reverse(branches), []}, rest}
    end
  end

  defp parse_for(tokens, ctx, line) do
    {target, rest} = parse_assign_target(tokens, extra_end: ["in"])

    rest = expect(rest, :name, "in")
    {iter, rest} = parse_tuple(rest, with_condexpr: false, extra_end: ["recursive"])

    {test, rest} =
      case rest do
        [{:name, "if", _} | [token | _] = rest] ->
          {test, rest} = parse_expression(rest)
          {{test, debug_line(test, token)}, rest}

        rest ->
          {nil, rest}
      end

    {recursive?, rest} =
      case rest do
        [{:name, "recursive", _} | rest] -> {true, rest}
        rest -> {false, rest}
      end

    {body, rest} = parse_statements(rest, ["endfor", "else"], %{ctx | loop: true})

    {else_body, rest} =
      case rest do
        [{:name, "endfor", _} | rest] -> {[], rest}
        [{:name, "else", _} | rest] -> parse_statements(rest, ["endfor"], ctx, true)
      end

    if "loop" in store_names([target, body, else_body]),
      do: fail("Can't assign to special loop variable in for-loop target", line(hd(tokens)))

    {{:for, target, iter, test, body, else_body, recursive?, line, nil}, rest}
  end

  # The line of the namespace check of a set is the line before the set, which parse/2 fills in.
  defp parse_set(tokens, ctx, line) do
    {target, rest} = parse_assign_target(tokens, with_namespace: true)

    case rest do
      [{:operator, "=", _} | rest] ->
        {expr, rest} = parse_tuple(rest)
        {{:set, target, expr, line, nil}, rest}

      rest ->
        {filter, rest} = parse_filter(nil, rest)
        {body, rest} = parse_statements(rest, ["endset"], ctx, true)
        {{:set_block, target, filter, body, line, nil}, rest}
    end
  end

  defp parse_macro(tokens, ctx, line) do
    {{:name, name}, rest} = parse_assign_target(tokens, name_only: true)
    {params, rest} = parse_signature(rest)
    {body, rest} = parse_statements(rest, ["endmacro"], %{ctx | loop: false}, true)
    {{:macro, name, params, body, special_names(body), line, nil}, rest}
  end

  defp parse_call_block(tokens, ctx, line) do
    {params, rest} =
      case tokens do
        [{:operator, "(", _} | _] -> parse_signature(tokens)
        tokens -> {[], tokens}
      end

    {call, rest} = parse_expression(rest)
    unless match?({:call, _, _, _, _}, call), do: fail("expected call", line(hd(tokens)))
    {body, rest} = parse_statements(rest, ["endcall"], %{ctx | loop: false}, true)
    {{:call_block, call, params, body, special_names(body), line, nil}, rest}
  end

  defp parse_filter_block(tokens, ctx, line) do
    {filter, rest} = parse_filter(nil, tokens, true)
    {body, rest} = parse_statements(rest, ["endfilter"], ctx, true)
    {{:filter_block, filter, body, line, nil}, rest}
  end

  defp parse_with(tokens, ctx), do: parse_with(tokens, ctx, [])

  defp parse_with([{:block_end, _, _} | _] = tokens, ctx, assignments) do
    {body, rest} = parse_statements(tokens, ["endwith"], ctx, true)
    {{:with, Enum.reverse(assignments), body, nil, nil}, rest}
  end

  defp parse_with(tokens, ctx, assignments) do
    tokens = if assignments == [], do: tokens, else: expect(tokens, :operator, ",")
    {target, rest} = parse_assign_target(tokens)
    rest = expect(rest, :operator, "=")
    {value, rest} = parse_expression(rest)
    parse_with(rest, ctx, [{target, value} | assignments])
  end

  # Like a with block, the autoescape tag is a scope, and its value has the line of the code before it.
  defp parse_autoescape(tokens, ctx) do
    {expr, rest} = parse_expression(tokens)
    {body, rest} = parse_statements(rest, ["endautoescape"], ctx, true)
    {{:autoescape, expr, body, nil, nil}, rest}
  end

  defp parse_print(tokens), do: parse_print(tokens, [])

  defp parse_print([{:block_end, _, _} | _] = tokens, nodes), do: {Enum.reverse(nodes), tokens}

  defp parse_print(tokens, nodes) do
    tokens = if nodes == [], do: tokens, else: expect(tokens, :operator, ",")
    {expr, rest} = parse_expression(tokens)
    parse_print(rest, [{:output, expr, debug_line(expr, hd(tokens))} | nodes])
  end

  defp parse_generation(tokens, ctx) do
    {body, rest} = parse_statements(tokens, ["endgeneration"], %{ctx | loop: false}, true)
    {{:generation, body, nil}, rest}
  end

  defp parse_signature(tokens) do
    tokens = expect(tokens, :operator, "(")
    parse_signature(tokens, [])
  end

  defp parse_signature([{:operator, ")", _} | rest], params), do: {Enum.reverse(params), rest}

  defp parse_signature(tokens, params) do
    tokens = if params == [], do: tokens, else: expect(tokens, :operator, ",")

    case tokens do
      [{:operator, ")", _} | rest] ->
        {Enum.reverse(params), rest}

      tokens ->
        {{:name, name}, rest} = parse_assign_target(tokens, name_only: true)
        parse_param(name, rest, params)
    end
  end

  defp parse_param(name, [{:operator, "=", _} | rest], params) do
    {default, rest} = parse_expression(rest)
    parse_signature(rest, [{name, default} | params])
  end

  defp parse_param(name, [token | _] = rest, params) do
    if Enum.any?(params, fn {_, default} -> default end),
      do: fail("non-default argument follows default argument", line(token))

    parse_signature(rest, [{name, nil} | params])
  end

  defp special_names(body), do: body |> collect_names(MapSet.new()) |> MapSet.to_list()

  defp collect_names({:name, name}, names) when name in @special_names,
    do: MapSet.put(names, name)

  defp collect_names(node, names) when is_tuple(node),
    do: node |> Tuple.to_list() |> collect_names(names)

  defp collect_names(nodes, names) when is_list(nodes),
    do: Enum.reduce(nodes, names, &collect_names/2)

  defp collect_names(_node, names), do: names

  # The names that the targets of set statements and for loops in `node` assign.
  defp store_names({:set, target, _value, _line, _check_line}), do: target_names(target)

  defp store_names({:set_block, target, _filter, body, _line, _scope}),
    do: target_names(target) ++ store_names(body)

  defp store_names({:for, target, _iter, _test, body, else_body, _recursive, _line, _scope}),
    do: target_names(target) ++ store_names([body, else_body])

  defp store_names(node) when is_tuple(node), do: node |> Tuple.to_list() |> store_names()
  defp store_names(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &store_names/1)
  defp store_names(_leaf), do: []

  defp target_names({:name, name}), do: [name]
  defp target_names({:tuple, items}), do: Enum.flat_map(items, &target_names/1)
  defp target_names(_target), do: []

  defp parse_assign_target(tokens, opts \\ []) do
    {target, rest} =
      if opts[:name_only] do
        parse_name_target(tokens)
      else
        opts = [
          simplified: true,
          extra_end: opts[:extra_end],
          with_namespace: opts[:with_namespace]
        ]

        parse_tuple(tokens, opts)
      end

    unless assignable?(target),
      do: fail("can't assign to #{repr(node_type(target))}", line(hd(tokens)))

    {target, rest}
  end

  defp parse_name_target([{:name, name, _} | rest]), do: {{:name, name}, rest}
  defp parse_name_target(tokens), do: expect(tokens, :name)

  defp assignable?({:name, name}), do: name not in ~w(true false none True False None)
  defp assignable?({:ns_ref, _, _}), do: true
  defp assignable?({:tuple, items}), do: Enum.all?(items, &assignable?/1)
  defp assignable?(_target), do: false

  defp node_type(node), do: node |> elem(0) |> Atom.to_string()

  ## Expressions

  defp parse_expression(tokens, with_condexpr \\ true) do
    if with_condexpr, do: parse_condexpr(tokens), else: parse_or(tokens)
  end

  defp parse_condexpr([token | _] = tokens) do
    {expr, rest} = parse_or(tokens)
    parse_condexpr_tail(expr, rest, line(token))
  end

  defp parse_condexpr_tail(expr, [{:name, "if", _} | rest], line) do
    {test, rest} = parse_or(rest)

    {else_expr, [next | _] = rest} =
      case rest do
        [{:name, "else", _} | rest] ->
          parse_condexpr(rest)

        rest ->
          {{:cond_undefined, line}, rest}
      end

    parse_condexpr_tail({:cond, test, expr, else_expr, line}, rest, line(next))
  end

  defp parse_condexpr_tail(expr, rest, _line), do: {expr, rest}

  defp parse_or(tokens), do: parse_logical(tokens, "or", :or, &parse_and/1)
  defp parse_and(tokens), do: parse_logical(tokens, "and", :and, &parse_not/1)

  # Like Jinja2, the first node of a chain such as `a or b or c` gets the line where the chain starts,
  # and each other node the line of its operator.
  defp parse_logical([token | _] = tokens, keyword, node, parse_operand) do
    {left, rest} = parse_operand.(tokens)
    parse_logical_tail(left, rest, keyword, node, parse_operand, line(token))
  end

  defp parse_logical_tail(left, [{:name, keyword, _} | rest], keyword, node, parse_operand, line) do
    {right, [next | _] = rest} = parse_operand.(rest)
    parse_logical_tail({node, left, right, line}, rest, keyword, node, parse_operand, line(next))
  end

  defp parse_logical_tail(left, rest, _keyword, _node, _parse_operand, _line), do: {left, rest}

  defp parse_not([{:name, "not", _} | rest]) do
    {expr, rest} = parse_not(rest)
    {{:not, expr}, rest}
  end

  defp parse_not(tokens), do: parse_compare(tokens)

  # Jinja2 gives a comparison the line of the token after its last operand.
  defp parse_compare(tokens) do
    {expr, rest} = parse_math1(tokens)

    case parse_compare_ops(rest, []) do
      {[], rest} -> {expr, rest}
      {ops, [next | _] = rest} -> {{:compare, expr, ops, line(next)}, rest}
    end
  end

  defp parse_compare_ops([{:operator, op, _} | rest] = tokens, ops) do
    case @compare_ops do
      %{^op => name} -> compare_operand(name, rest, ops)
      _ -> {Enum.reverse(ops), tokens}
    end
  end

  defp parse_compare_ops([{:name, "in", _} | rest], ops), do: compare_operand(:in, rest, ops)

  defp parse_compare_ops([{:name, "not", _}, {:name, "in", _} | rest], ops),
    do: compare_operand(:notin, rest, ops)

  defp parse_compare_ops(tokens, ops), do: {Enum.reverse(ops), tokens}

  defp compare_operand(op, tokens, ops) do
    {operand, rest} = parse_math1(tokens)
    parse_compare_ops(rest, [{op, operand} | ops])
  end

  defp parse_math1(tokens), do: parse_binary(tokens, @math1_ops, &parse_concat/1)
  defp parse_math2(tokens), do: parse_binary(tokens, @math2_ops, &parse_pow/1)
  defp parse_pow(tokens), do: parse_binary(tokens, %{"**" => :pow}, &parse_unary/1)

  defp parse_binary([token | _] = tokens, ops, parse_operand) do
    {left, rest} = parse_operand.(tokens)
    parse_binary_tail(left, rest, ops, parse_operand, line(token))
  end

  defp parse_binary_tail(left, [{:operator, op, _} | rest] = tokens, ops, parse_operand, line) do
    case ops do
      %{^op => name} ->
        {right, [next | _] = rest} = parse_operand.(rest)
        parse_binary_tail({:binop, name, left, right, line}, rest, ops, parse_operand, line(next))

      _ ->
        {left, tokens}
    end
  end

  defp parse_binary_tail(left, tokens, _ops, _parse_operand, _line), do: {left, tokens}

  defp parse_concat(tokens) do
    {first, rest} = parse_math2(tokens)
    parse_concat_tail([first], rest)
  end

  defp parse_concat_tail(args, [{:operator, "~", _} | rest]) do
    {arg, rest} = parse_math2(rest)
    parse_concat_tail([arg | args], rest)
  end

  defp parse_concat_tail([arg], rest), do: {arg, rest}
  defp parse_concat_tail(args, rest), do: {{:concat, Enum.reverse(args)}, rest}

  defp parse_unary(tokens, with_filter \\ true) do
    {node, rest} =
      case tokens do
        [{:operator, "-", _} | rest] ->
          {operand, rest} = parse_unary(rest, false)
          {{:neg, operand}, rest}

        [{:operator, "+", _} | rest] ->
          {operand, rest} = parse_unary(rest, false)
          {{:pos, operand}, rest}

        tokens ->
          parse_primary(tokens)
      end

    {node, rest} = parse_postfix(node, rest)
    if with_filter, do: parse_filter_expr(node, rest), else: {node, rest}
  end

  defp parse_primary(tokens, with_namespace \\ false)

  defp parse_primary([{:name, name, _} | rest], with_namespace) do
    case {name, rest} do
      {name, rest} when name in ["true", "True"] ->
        {{:const, true}, rest}

      {name, rest} when name in ["false", "False"] ->
        {{:const, false}, rest}

      {name, rest} when name in ["none", "None"] ->
        {{:const, nil}, rest}

      {name, [{:operator, ".", _} | rest]} when with_namespace ->
        case rest do
          [{:name, attr, _} | rest] -> {{:ns_ref, name, attr}, rest}
          rest -> expect(rest, :name)
        end

      {name, rest} ->
        {{:name, name}, rest}
    end
  end

  defp parse_primary([{:string, value, _} | rest], _with_namespace),
    do: parse_strings(rest, [value])

  defp parse_primary([{type, value, _} | rest], _with_namespace) when type in [:integer, :float],
    do: {{:const, value}, rest}

  defp parse_primary([{:operator, "(", _} | rest], _with_namespace) do
    {expr, rest} = parse_tuple(rest, explicit_parentheses: true)
    {expr, expect(rest, :operator, ")")}
  end

  defp parse_primary([{:operator, "[", _} | rest], _with_namespace), do: parse_list(rest, [])
  defp parse_primary([{:operator, "{", _} | rest], _with_namespace), do: parse_dict(rest, [])

  defp parse_primary([token | _], _with_namespace),
    do: fail("unexpected #{inspect_token(token)}", line(token))

  defp parse_strings([{:string, value, _} | rest], acc), do: parse_strings(rest, [value | acc])

  defp parse_strings(rest, acc),
    do: {{:const, acc |> Enum.reverse() |> IO.iodata_to_binary()}, rest}

  defp parse_tuple(tokens, opts \\ []) do
    parse =
      if opts[:simplified],
        do: &parse_primary(&1, opts[:with_namespace] || false),
        else: &parse_expression(&1, Keyword.get(opts, :with_condexpr, true))

    parse_tuple_items(tokens, parse, opts, [])
  end

  defp parse_tuple_items(tokens, parse, opts, items) do
    tokens = if items == [], do: tokens, else: expect(tokens, :operator, ",")

    if tuple_end?(tokens, opts[:extra_end]) do
      finish_tuple(tokens, opts, items, items != [])
    else
      {item, rest} = parse.(tokens)

      case rest do
        [{:operator, ",", _} | _] -> parse_tuple_items(rest, parse, opts, [item | items])
        rest -> finish_tuple(rest, opts, [item | items], items != [])
      end
    end
  end

  defp finish_tuple(tokens, _opts, items, true), do: {{:tuple, Enum.reverse(items)}, tokens}
  defp finish_tuple(tokens, _opts, [item], false), do: {item, tokens}

  defp finish_tuple(tokens, opts, [], _tuple?),
    do: empty_tuple(tokens, opts[:explicit_parentheses])

  defp empty_tuple(tokens, true), do: {{:tuple, []}, tokens}

  defp empty_tuple([token | _], _explicit),
    do: fail("Expected an expression, got #{inspect_token(token)}", line(token))

  defp tuple_end?([{type, _, _} | _], _extra) when type in [:variable_end, :block_end], do: true
  defp tuple_end?([{:operator, ")", _} | _], _extra), do: true
  defp tuple_end?([{:name, name, _} | _], extra) when is_list(extra), do: name in extra
  defp tuple_end?(_tokens, _extra), do: false

  defp parse_list([{:operator, "]", _} | rest], items), do: {{:list, Enum.reverse(items)}, rest}

  defp parse_list(tokens, items) do
    tokens = if items == [], do: tokens, else: expect(tokens, :operator, ",")

    case tokens do
      [{:operator, "]", _} | rest] ->
        {{:list, Enum.reverse(items)}, rest}

      tokens ->
        {item, rest} = parse_expression(tokens)
        parse_list(rest, [item | items])
    end
  end

  defp parse_dict([{:operator, "}", _} | rest], pairs), do: {{:dict, Enum.reverse(pairs)}, rest}

  defp parse_dict(tokens, pairs) do
    tokens = if pairs == [], do: tokens, else: expect(tokens, :operator, ",")

    case tokens do
      [{:operator, "}", _} | rest] ->
        {{:dict, Enum.reverse(pairs)}, rest}

      tokens ->
        {key, rest} = parse_expression(tokens)
        rest = expect(rest, :operator, ":")
        {value, rest} = parse_expression(rest)
        parse_dict(rest, [{key, value} | pairs])
    end
  end

  defp parse_postfix(node, [{:operator, op, _} | _] = tokens) when op in [".", "["] do
    {node, rest} = parse_subscript(node, tokens)
    parse_postfix(node, rest)
  end

  defp parse_postfix(node, [{:operator, "(", _} | _] = tokens) do
    {node, rest} = parse_call(node, tokens)
    parse_postfix(node, rest)
  end

  defp parse_postfix(node, tokens), do: {node, tokens}

  defp parse_filter_expr(node, [{:operator, "|", _} | _] = tokens) do
    {node, rest} = parse_filter(node, tokens)
    parse_filter_expr(node, rest)
  end

  defp parse_filter_expr(node, [{:name, "is", _} | _] = tokens) do
    {node, rest} = parse_test(node, tokens)
    parse_filter_expr(node, rest)
  end

  defp parse_filter_expr(node, [{:operator, "(", _} | _] = tokens) do
    {node, rest} = parse_call(node, tokens)
    parse_filter_expr(node, rest)
  end

  defp parse_filter_expr(node, tokens), do: {node, tokens}

  defp parse_subscript(node, [{:operator, ".", line} | rest]) do
    case rest do
      [{:name, name, _} | rest] -> {{:getattr, node, name, line}, rest}
      [{:integer, index, _} | rest] -> {{:getitem, node, {:const, index}, line}, rest}
      [token | _] -> fail("expected name or number", line(token))
    end
  end

  defp parse_subscript(node, [{:operator, "[", line} | rest]) do
    {args, rest} = parse_subscribed_list(rest, [])

    case args do
      [arg] -> {{:getitem, node, arg, line}, rest}
      args -> {{:getitem, node, {:tuple, args}, line}, rest}
    end
  end

  defp parse_subscribed_list([{:operator, "]", _} | rest], args), do: {Enum.reverse(args), rest}

  defp parse_subscribed_list(tokens, args) do
    tokens = if args == [], do: tokens, else: expect(tokens, :operator, ",")
    {arg, rest} = parse_subscribed(tokens)
    parse_subscribed_list(rest, [arg | args])
  end

  defp parse_subscribed([{:operator, ":", _} | rest]), do: parse_slice(nil, rest)

  defp parse_subscribed(tokens) do
    case parse_expression(tokens) do
      {start, [{:operator, ":", _} | rest]} -> parse_slice(start, rest)
      result -> result
    end
  end

  defp parse_slice(start, tokens) do
    {stop, rest} = slice_part(tokens)

    {step, rest} =
      case rest do
        [{:operator, ":", _} | rest] -> slice_part(rest)
        rest -> {nil, rest}
      end

    {{:slice, start, stop, step}, rest}
  end

  defp slice_part([{:operator, op, _} | _] = tokens) when op in [":", "]", ","], do: {nil, tokens}
  defp slice_part(tokens), do: parse_expression(tokens)

  defp parse_call(node, [token | _] = tokens) do
    {args, kwargs, rest} = parse_call_args(tokens)
    {{:call, node, args, kwargs, line(token)}, rest}
  end

  defp parse_call_args([{:operator, "(", line} | rest]), do: parse_call_args(rest, line, [], [])

  defp parse_call_args(tokens), do: expect(tokens, :operator, "(")

  defp parse_call_args([{:operator, ")", _} | rest], _line, args, kwargs),
    do: {Enum.reverse(args), Enum.reverse(kwargs), rest}

  defp parse_call_args(tokens, line, args, kwargs) do
    case if(args == [] and kwargs == [], do: tokens, else: expect(tokens, :operator, ",")) do
      [{:operator, ")", _} | rest] -> {Enum.reverse(args), Enum.reverse(kwargs), rest}
      tokens -> parse_call_arg(tokens, line, args, kwargs)
    end
  end

  defp parse_call_arg([{:operator, "*", _} | rest], line, args, kwargs) do
    ensure_call(not unpacked?(args) and not unpacked?(kwargs), line)
    {expr, rest} = parse_expression(rest)
    parse_call_args(rest, line, [{:unpack, expr} | args], kwargs)
  end

  defp parse_call_arg([{:operator, "**", _} | rest], line, args, kwargs) do
    ensure_call(not unpacked?(kwargs), line)
    {expr, rest} = parse_expression(rest)
    parse_call_args(rest, line, args, [{:unpack, expr} | kwargs])
  end

  defp parse_call_arg([{:name, name, _}, {:operator, "=", _} | rest], line, args, kwargs) do
    ensure_call(not unpacked?(kwargs), line)
    {expr, rest} = parse_expression(rest)
    parse_call_args(rest, line, args, [{name, expr} | kwargs])
  end

  defp parse_call_arg(tokens, line, args, kwargs) do
    ensure_call(not unpacked?(args) and not unpacked?(kwargs) and kwargs == [], line)
    {expr, rest} = parse_expression(tokens)
    parse_call_args(rest, line, [expr | args], kwargs)
  end

  defp unpacked?(items), do: Enum.any?(items, &match?({:unpack, _}, &1))

  defp ensure_call(true, _line), do: :ok
  defp ensure_call(false, line), do: fail("invalid syntax for function call expression", line)

  defp parse_filter(node, tokens, start_inline \\ false)

  defp parse_filter(node, [{:operator, "|", _} | rest], false), do: parse_filter(node, rest, true)

  defp parse_filter(node, [token | _] = tokens, true) do
    {name, rest} = parse_dotted_name(tokens)

    {args, kwargs, rest} =
      case rest do
        [{:operator, "(", _} | _] -> parse_call_args(rest)
        rest -> {[], [], rest}
      end

    parse_filter({:filter, name, node, args, kwargs, line(token)}, rest, false)
  end

  defp parse_filter(node, tokens, false), do: {node, tokens}

  defp parse_dotted_name(tokens) do
    {name, rest} =
      case tokens do
        [{:name, name, _} | rest] -> {name, rest}
        tokens -> {nil, expect(tokens, :name)}
      end

    parse_dotted_tail(name, rest)
  end

  defp parse_dotted_tail(name, [{:operator, ".", _} | rest]) do
    {part, rest} = parse_dotted_name(rest)
    {name <> "." <> part, rest}
  end

  defp parse_dotted_tail(name, rest), do: {name, rest}

  defp parse_test(node, [{:name, "is", line} | rest]) do
    {negated?, rest} =
      case rest do
        [{:name, "not", _} | rest] -> {true, rest}
        rest -> {false, rest}
      end

    {name, rest} = parse_dotted_name(rest)

    {args, kwargs, rest} = parse_test_args(rest)
    test = {:test, name, node, args, kwargs, line}
    {if(negated?, do: {:not, test, line}, else: test), rest}
  end

  defp parse_test_args([{:operator, "(", _} | _] = tokens), do: parse_call_args(tokens)

  defp parse_test_args([{:name, "is", line} | _]),
    do: fail("You cannot chain multiple tests with is", line)

  defp parse_test_args([{:name, name, _} | _] = tokens) when name in ["else", "or", "and"],
    do: {[], [], tokens}

  defp parse_test_args([{type, value, _} | _] = tokens)
       when type in [:name, :string, :integer, :float] or value in ["[", "{"] do
    {arg, rest} = parse_primary(tokens)
    {arg, rest} = parse_postfix(arg, rest)
    {[arg], [], rest}
  end

  defp parse_test_args(tokens), do: {[], [], tokens}

  # The line of the outermost node of an expression, which Jinja2 gives to the errors of an output.
  defp debug_line({:getattr, _expr, _name, line}, _token), do: line
  defp debug_line({:getitem, _expr, _key, line}, _token), do: line
  defp debug_line({:call, _callee, _args, _kwargs, line}, _token), do: line
  defp debug_line({:filter, _name, _expr, _args, _kwargs, line}, _token), do: line
  defp debug_line({:test, _name, _expr, _args, _kwargs, line}, _token), do: line
  defp debug_line({:not, _test, line}, _token), do: line

  defp debug_line({type, _left, _right, line}, _token) when type in [:and, :or, :compare],
    do: line

  defp debug_line({:binop, _op, _left, _right, line}, _token), do: line
  defp debug_line({:cond, _test, _then, _else, line}, _token), do: line
  defp debug_line(_expr, token), do: line(token)

  ## Token helpers

  defp skip_if([{type, value, _} | rest], type, value), do: rest
  defp skip_if(tokens, _type, _value), do: tokens

  defp expect([{type, _, _} | rest], type) when type != :operator, do: rest

  defp expect([token | _], type), do: fail_expect(token, describe_type(type))

  defp expect([{type, value, _} | rest], type, value), do: rest
  defp expect([token | _], _type, value), do: fail_expect(token, value)

  defp fail_expect({:eof, _, line}, expected),
    do: fail("unexpected end of template, expected #{repr(expected)}.", line)

  defp fail_expect(token, expected),
    do: fail("expected token #{repr(expected)}, got #{repr(describe(token))}", line(token))

  defp fail_unexpected_tag(name, ctx, line) do
    looking = ctx.ends |> List.first() |> Kernel.||([]) |> Enum.map_join(" or ", &repr/1)

    message = [
      if(name, do: "Encountered unknown tag #{repr(name)}.", else: "Unexpected end of template."),
      cond do
        looking == "" ->
          nil

        name && name in List.flatten(ctx.ends) ->
          "You probably made a nesting mistake. Jinja is expecting this tag, but currently looking for #{looking}."

        true ->
          "Jinja was looking for the following tags: #{looking}."
      end,
      if(ctx.tags != [],
        do: "The innermost block that needs to be closed is #{repr(hd(ctx.tags))}."
      )
    ]

    fail(message |> Enum.reject(&is_nil/1) |> Enum.join(" "), line)
  end

  defp describe({:name, name, _}), do: name
  defp describe({:operator, op, _}), do: op
  defp describe({type, _, _}), do: describe_type(type)

  defp describe_type(:block_begin), do: "begin of statement block"
  defp describe_type(:block_end), do: "end of statement block"
  defp describe_type(:variable_begin), do: "begin of print statement"
  defp describe_type(:variable_end), do: "end of print statement"
  defp describe_type(:data), do: "template data / text"
  defp describe_type(:eof), do: "end of template"
  defp describe_type(type), do: Atom.to_string(type)

  defp inspect_token(token), do: repr(describe(token))

  defp line({_, _, line}), do: line

  defp repr(value), do: Otera.Value.repr(value)

  defp fail(message, line), do: raise(SyntaxError, message: message, line: line)
end
