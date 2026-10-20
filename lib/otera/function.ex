defmodule Otera.Function do
  @moduledoc """
  An Elixir function with a Python signature, for a global, filter or test that takes keyword arguments.

      greet = Otera.Function.new("greet", ["name", {"punctuation", "!"}], fn name, punctuation ->
        "Hello, " <> name <> punctuation
      end)

      Otera.render("{{ greet('Ann', punctuation='?') }}", %{}, globals: %{"greet" => greet})
      #=> {:ok, "Hello, Ann?"}

  A param is a name for a required argument, or `{name, default}`. Otera binds the positional and keyword arguments of a call to the params like a Python call, and calls `fun` with one value for each param. A wrong call raises the `TypeError` of Python, with `name` in the message. For a filter or a test, the first param is the value.

  A plain Elixir function gets the positional arguments only.
  """

  defstruct [:name, :params, :fun]

  @type param :: String.t() | {String.t(), term}
  @type t :: %__MODULE__{name: String.t(), params: [param], fun: function}

  @doc """
  Makes a function with the Python name `name` and the params `params`. `fun` takes one argument for each param.
  """
  @spec new(String.t(), [param], function) :: t
  def new(name, params, fun) when is_function(fun, length(params)),
    do: %__MODULE__{name: name, params: params, fun: fun}
end
