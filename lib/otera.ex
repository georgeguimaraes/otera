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

  A function gets the positional arguments of the call. When it takes one more argument, it also gets the keyword arguments as a map with string keys. Values that a function returns become template values, like variables.

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

    {:ok, %Template{source: source, ast: ast, options: opts}}
  rescue
    error in Otera.SyntaxError -> {:error, error}
  end

  @doc """
  Renders a template, given as source or as a parsed `Otera.Template`, with `variables`.

  `variables` is a map or a keyword list. Returns `{:ok, string}`, or `{:error, exception}` with an `Otera.SyntaxError` or an `Otera.Error`.
  """
  @spec render(String.t() | Template.t(), map | keyword, keyword) ::
          {:ok, String.t()} | {:error, error}
  def render(template, variables \\ %{}, opts \\ [])

  def render(%Template{ast: ast, options: template_opts}, variables, opts) do
    opts = merge_options(template_opts, opts)

    variables =
      Map.new(variables, fn {name, value} -> {to_string(name), Value.from_elixir(value)} end)

    {:ok, Evaluator.render(ast, variables, opts)}
  rescue
    error in Otera.Error -> {:error, error}
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
