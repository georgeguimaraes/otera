defmodule Otera do
  @moduledoc """
  Otera (お寺, "temple") renders Jinja templates in pure Elixir, with the semantics of Python Jinja2.

      iex> Otera.render("Hello {{ name }}!", %{name: "World"})
      {:ok, "Hello World!"}

  Variables are Elixir values, which templates see as Python values: maps are dicts, lists are lists, `nil` is `None`, and atom keys become strings. See `Otera.Value` for the full mapping, and `Otera.Dict` for the key order of dicts.

  To render the chat template of a Hugging Face model like transformers, see `Otera.ChatTemplate`.

  ## Options

    * `:trim_blocks` - removes the first newline after a block tag. The default is `false`.
    * `:lstrip_blocks` - removes the spaces and tabs before a block tag at the start of a line. The default is `false`.
    * `:keep_trailing_newline` - keeps the final newline of the template. The default is `false`.
    * `:globals` - a map of names to values or Elixir functions that the template can use.
    * `:filters` - a map of names to Elixir functions, called with the value and the filter arguments.
    * `:tests` - a map of names to Elixir functions, called with the value and the test arguments.
    * `:autoescape` - escapes the HTML characters in the output of each `{{ ... }}`, except an `Otera.Markup`. A boolean, or a function that gets the name of the template and gives a boolean, like `select_autoescape` of Jinja2. A template from a string has the name `nil`. The default is `false`.
    * `:loader` - the templates that `{% extends %}`, `{% include %}`, `{% import %}` and `load/2` can load by name. See `Otera.Loader`.
    * `:name` - the name of the template for `parse/2`, which errors and autoescape use. `load/2` gives each template its name.

  A plain Elixir function gets the positional arguments of the call. For keyword arguments and defaults, give an `Otera.Function`, which has a Python signature. Values that a function returns become template values, like variables.

  The `break` and `continue` statements of the `loopcontrols` extension and the `{% generation %}` block of transformers are always available.
  """

  alias Otera.{Evaluator, Lexer, Parser, Template, Value}

  @type error :: Otera.SyntaxError.t() | Otera.Error.t()

  @doc """
  Parses `source` into a template that renders many times.

  The options are the options of the module documentation. They apply to every render of the template.
  """
  @spec parse(String.t(), keyword) :: {:ok, Template.t()} | {:error, Otera.SyntaxError.t()}
  def parse(source, opts \\ []) do
    names = fn key -> opts |> Keyword.get(key, %{}) |> Map.keys() |> Enum.map(&to_string/1) end

    ast =
      source
      |> Lexer.tokenize(opts)
      |> Parser.parse(filters: names.(:filters), tests: names.(:tests))

    {ast, scope} = Otera.Scope.annotate(ast)

    blocks =
      for {:block, name, _, _, _, _, _} = block <- Parser.blocks(ast),
          into: %{},
          do: {name, block}

    {:ok,
     %Template{
       name: opts[:name],
       source: source,
       ast: ast,
       scope: scope,
       blocks: blocks,
       extends?: Parser.extends?(ast),
       options: opts
     }}
  rescue
    error in Otera.SyntaxError -> {:error, %{error | name: opts[:name]}}
  end

  @doc """
  Loads the template `name` with the `:loader` option, like `get_template` of Jinja2.

  Returns `{:ok, template}`, `{:error, %Otera.Error{kind: :template_not_found}}` when the loader has no template with that name, or `{:error, %Otera.SyntaxError{}}`. The other options are the options of `parse/2`.

      iex> {:ok, template} = Otera.load("hello.txt", loader: %{"hello.txt" => "Hello {{ name }}!"})
      iex> Otera.render(template, %{name: "World"})
      {:ok, "Hello World!"}
  """
  @spec load(String.t(), keyword) :: {:ok, Template.t()} | {:error, error}
  def load(name, opts) do
    {:ok, Template.load(name, opts)}
  rescue
    error in [Otera.SyntaxError, Otera.Error] -> {:error, error}
  end

  @doc """
  Renders a template, given as source or as a parsed `Otera.Template`, with `variables`.

  `variables` is a map or a keyword list. Returns `{:ok, string}`, or `{:error, exception}` with an `Otera.SyntaxError` or an `Otera.Error`.
  """
  @spec render(String.t() | Template.t(), map | keyword, keyword) ::
          {:ok, String.t()} | {:error, error}
  def render(template, variables \\ %{}, opts \\ [])

  def render(%Template{options: template_opts} = template, variables, opts) do
    opts = merge_options(template_opts, opts)

    variables =
      Map.new(variables, fn {name, value} -> {to_string(name), Value.from_elixir(value)} end)

    {:ok, Evaluator.render(template, variables, opts)}
  rescue
    error in [Otera.Error, Otera.SyntaxError] -> {:error, error}
  end

  def render(source, variables, opts) when is_binary(source) do
    with {:ok, template} <- parse(source, opts), do: render(template, variables)
  end

  @doc """
  Like `render/3`, but raises the error.
  """
  @spec render!(String.t() | Template.t(), map | keyword, keyword) :: String.t()
  def render!(template, variables \\ %{}, opts \\ []) do
    case render(template, variables, opts) do
      {:ok, output} -> output
      {:error, error} -> raise error
    end
  end

  defp merge_options(template_opts, opts) do
    Keyword.merge(template_opts, opts, fn
      key, left, right when key in [:globals, :filters, :tests] -> Map.merge(left, right)
      _key, _left, right -> right
    end)
  end
end
