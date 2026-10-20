defmodule Otera.Scope do
  @moduledoc """
  The static scopes of Jinja2, from its `idtracking` module.

  Jinja2 compiles each scope of a template to the local variables of a Python function: the root of the template, a block, a macro, a `caller`, the body of a loop, a with block and others. At the start of a scope, each name that the scope sets before it reads it starts as missing, also when the render has a variable with that name. A loop that reads `x` before a later top-level `{% set x = 1 %}` sees `x` as undefined. At the end of a scope that is not a function, such as a loop, its names become missing again, which a macro that the scope defined can see.

  `annotate/1` analyzes the scopes of a syntax tree like Jinja2, and gives each node that opens a scope its `t:t/0`. The evaluator applies them.
  """

  @typedoc """
  `unset` lists the names that are missing at the start of the scope. `exit` gives the value of each name of the scope after the scope ends: `:missing` for a parameter, such as the target of a loop, which prints as `missing`, and `:unset` for the others, which are undefined.
  """
  @type t :: %{unset: [String.t()], exit: %{String.t() => :missing | :unset}}

  defstruct refs: %{}, stores: MapSet.new(), parent: nil

  @doc """
  Returns the syntax tree with the scope of each node that opens one, and the scope of the root.
  """
  @spec annotate(list) :: {list, t}
  def annotate(body) do
    symbols = visit(%__MODULE__{}, body)
    {annotate_nodes(body, symbols), scope(symbols)}
  end

  defp scope(symbols) do
    %{
      unset: for({name, :undefined} <- symbols.refs, do: name),
      exit: Map.new(symbols.refs, fn {name, kind} -> {name, exit_value(kind)} end)
    }
  end

  defp exit_value(:param), do: :missing
  defp exit_value(_kind), do: :unset

  ## Annotation: the scopes inside the scope `parent`

  defp annotate_nodes(nodes, parent) when is_list(nodes),
    do: Enum.map(nodes, &annotate_node(&1, parent))

  defp annotate_node({:if, branches, else_body}, parent) do
    branches = for {test, body, line} <- branches, do: {test, annotate_nodes(body, parent), line}
    {:if, branches, annotate_nodes(else_body, parent)}
  end

  defp annotate_node({:for, target, iter, test, body, else_body, recursive?, line, nil}, parent) do
    params = if recursive? or loads?(body, "loop"), do: ["loop"], else: []
    body_symbols = %__MODULE__{parent: parent} |> declare([target | params]) |> visit(body)
    else_symbols = visit(%__MODULE__{parent: parent}, else_body)

    {:for, target, iter, test, annotate_nodes(body, body_symbols),
     annotate_nodes(else_body, else_symbols), recursive?, line,
     {scope(body_symbols), scope(else_symbols)}}
  end

  defp annotate_node({:with, assignments, body, line, nil}, parent) do
    targets = Enum.map(assignments, &elem(&1, 0))
    symbols = %__MODULE__{parent: parent} |> declare(targets) |> visit(body)
    {:with, assignments, annotate_nodes(body, symbols), line, scope(symbols)}
  end

  defp annotate_node({:macro, name, params, body, special_names, line, nil}, parent) do
    symbols = function_symbols(params, special_names, body, parent)
    {:macro, name, params, annotate_nodes(body, symbols), special_names, line, scope(symbols)}
  end

  defp annotate_node({:call_block, call, params, body, special_names, line, nil}, parent) do
    symbols = function_symbols(params, special_names, body, parent)

    {:call_block, call, params, annotate_nodes(body, symbols), special_names, line,
     scope(symbols)}
  end

  defp annotate_node({:set_block, target, filter, body, line, nil}, parent) do
    symbols = visit(%__MODULE__{parent: parent}, body)
    {:set_block, target, filter, annotate_nodes(body, symbols), line, scope(symbols)}
  end

  defp annotate_node({:filter_block, filter, body, line, nil}, parent) do
    symbols = %__MODULE__{parent: parent} |> visit(body) |> visit_expr(filter)
    {:filter_block, filter, annotate_nodes(body, symbols), line, scope(symbols)}
  end

  defp annotate_node({:autoescape, expr, body, line, nil}, parent) do
    symbols = %__MODULE__{parent: parent} |> visit_expr(expr) |> visit(body)
    {:autoescape, expr, annotate_nodes(body, symbols), line, scope(symbols)}
  end

  defp annotate_node({:generation, body, nil}, parent) do
    symbols = visit(%__MODULE__{parent: parent}, body)
    {:generation, annotate_nodes(body, symbols), scope(symbols)}
  end

  defp annotate_node(node, _parent), do: node

  # A macro or caller declares its parameters, then reads its defaults, then runs its body.
  defp function_symbols(params, special_names, body, parent) do
    names = Enum.map(params, &{:name, elem(&1, 0)}) ++ Enum.map(special_names, &{:name, &1})

    %__MODULE__{parent: parent}
    |> declare(names)
    |> visit_expr(Enum.map(params, &elem(&1, 1)))
    |> visit(body)
  end

  defp declare(symbols, targets), do: Enum.reduce(targets, symbols, &declare_target(&2, &1))

  defp declare_target(symbols, {:name, name}), do: put_ref(symbols, name, :param, true)
  defp declare_target(symbols, {:tuple, items}), do: declare(symbols, items)

  defp declare_target(symbols, name) when is_binary(name),
    do: put_ref(symbols, name, :param, true)

  ## The symbols of one scope, like FrameSymbolVisitor of Jinja2

  defp visit(symbols, nodes) when is_list(nodes), do: Enum.reduce(nodes, symbols, &visit(&2, &1))
  defp visit(symbols, {:output, expr, _line}), do: visit_expr(symbols, expr)

  defp visit(symbols, {:if, [{test, body, _line} | elifs], else_body}) do
    symbols = visit_expr(symbols, test)
    body_symbols = visit(symbols, body)
    elif_symbols = Enum.reduce(elifs, symbols, &visit_elif(&2, &1))
    else_symbols = visit(symbols, else_body)
    branch_update(symbols, [body_symbols, elif_symbols, else_symbols])
  end

  defp visit(symbols, {:for, _target, iter, _test, _body, _else, _recursive, _line, _scope}),
    do: visit_expr(symbols, iter)

  defp visit(symbols, {:set, target, expr, _line, _check_line}),
    do: symbols |> visit_expr(expr) |> visit_target(target)

  defp visit(symbols, {:set_block, target, _filter, _body, _line, _scope}),
    do: visit_target(symbols, target)

  defp visit(symbols, {:macro, name, _params, _body, _special, _line, _scope}),
    do: store(symbols, name)

  defp visit(symbols, {:call_block, call, _params, _body, _special, _line, _scope}),
    do: visit_expr(symbols, call)

  defp visit(symbols, {:filter_block, filter, _body, _line, _scope}),
    do: visit_expr(symbols, filter)

  defp visit(symbols, {:with, assignments, _body, _line, _scope}),
    do: visit_expr(symbols, Enum.map(assignments, &elem(&1, 1)))

  defp visit(symbols, _node), do: symbols

  # Jinja2 visits the branches in copies of the symbols, and all the elif branches in one copy,
  # each as a nested if. The symbols are immutable, so the copies are the same value.
  defp visit_elif(symbols, {test, body, _line}) do
    symbols = visit_expr(symbols, test)
    branch_update(symbols, [visit(symbols, body), symbols, symbols])
  end

  defp visit_target(symbols, {:name, name}), do: store(symbols, name)

  defp visit_target(symbols, {:tuple, items}),
    do: Enum.reduce(items, symbols, &visit_target(&2, &1))

  defp visit_target(symbols, {:ns_ref, name, _attr}), do: load(symbols, name)

  defp visit_expr(symbols, {:name, name}), do: load(symbols, name)
  defp visit_expr(symbols, node) when is_tuple(node), do: visit_expr(symbols, Tuple.to_list(node))

  defp visit_expr(symbols, nodes) when is_list(nodes),
    do: Enum.reduce(nodes, symbols, &visit_expr(&2, &1))

  defp visit_expr(symbols, _leaf), do: symbols

  ## Symbols, like the Symbols class of Jinja2

  defp find_ref(nil, _name), do: false

  defp find_ref(symbols, name),
    do: is_map_key(symbols.refs, name) or find_ref(symbols.parent, name)

  defp load(symbols, name),
    do: if(find_ref(symbols, name), do: symbols, else: put_ref(symbols, name, :resolve, false))

  defp store(symbols, name) do
    cond do
      is_map_key(symbols.refs, name) -> mark_store(symbols, name)
      find_ref(symbols.parent, name) -> put_ref(symbols, name, :alias, true)
      true -> put_ref(symbols, name, :undefined, true)
    end
  end

  defp put_ref(symbols, name, kind, store?) do
    symbols = %{symbols | refs: Map.put(symbols.refs, name, kind)}
    if store?, do: mark_store(symbols, name), else: symbols
  end

  defp mark_store(symbols, name), do: %{symbols | stores: MapSet.put(symbols.stores, name)}

  # A name that only some branches set starts with its outer value.
  defp branch_update(symbols, branches) do
    new_stores =
      branches
      |> Enum.map(& &1.stores)
      |> Enum.reduce(&MapSet.union/2)
      |> MapSet.difference(symbols.stores)

    symbols =
      Enum.reduce(branches, symbols, fn branch, symbols ->
        %{
          symbols
          | refs: Map.merge(symbols.refs, branch.refs),
            stores: MapSet.union(symbols.stores, branch.stores)
        }
      end)

    Enum.reduce(new_stores, symbols, fn name, symbols ->
      kind = if find_ref(symbols.parent, name), do: :alias, else: :resolve
      %{symbols | refs: Map.put(symbols.refs, name, kind)}
    end)
  end

  defp loads?({:name, name}, name), do: true
  defp loads?(node, name) when is_tuple(node), do: loads?(Tuple.to_list(node), name)
  defp loads?(nodes, name) when is_list(nodes), do: Enum.any?(nodes, &loads?(&1, name))
  defp loads?(_leaf, _name), do: false
end
