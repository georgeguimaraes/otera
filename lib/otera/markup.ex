defmodule Otera.Markup do
  @moduledoc """
  A string that is safe to insert into HTML, like `Markup` of markupsafe, which Jinja2 uses.

  With autoescape, Otera escapes the output of each `{{ ... }}`, except a `Markup`. The filters `safe`, `escape`, `forceescape` and `tojson` give a `Markup`, and with autoescape, macros, `caller()`, blocks and the bodies of set and filter blocks give a `Markup` too.

  Templates see a `Markup` as the Python `Markup`, a subclass of `str`. An operation that combines a `Markup` with a plain string escapes the plain string: `+`, `%`, `join`, `format` and the `replace` filter. Most string methods of a `Markup` give a `Markup`.

  To give a template a string that it does not escape, pass a `Markup` in the variables:

      Otera.render("{{ link }}", %{link: Otera.Markup.new(~s(<a href="/">Home</a>))}, autoescape: true)
      #=> {:ok, ~s(<a href="/">Home</a>)}

  A custom filter, test or function gets a `Markup` as this struct, and can return one.
  """

  alias Otera.{HTML, Value}

  defstruct text: ""

  @type t :: %__MODULE__{text: String.t()}

  @doc """
  Marks `text` as safe, like `Markup(text)`.
  """
  @spec new(String.t()) :: t
  def new(text) when is_binary(text), do: %__MODULE__{text: text}

  @doc """
  Escapes `value` like `markupsafe.escape`: a `Markup` stays as it is, and another value becomes the `Markup` of its escaped `str()`.
  """
  @spec escape(term) :: t
  def escape(%__MODULE__{} = markup), do: markup
  def escape(value), do: %__MODULE__{text: value |> Value.to_str() |> HTML.escape()}

  @doc """
  Like `markupsafe.soft_str`: a string or a `Markup` stays as it is, and another value becomes its `str()`.
  """
  @spec soft_str(term) :: String.t() | t
  def soft_str(%__MODULE__{} = markup), do: markup
  def soft_str(value), do: Value.to_str(value)

  @doc """
  Applies `fun` to the text of `value`, and gives a `Markup` back when `value` is a `Markup`.
  """
  @spec map(String.t() | t, (String.t() -> String.t())) :: String.t() | t
  def map(%__MODULE__{text: text}, fun), do: new(fun.(text))
  def map(text, fun) when is_binary(text), do: fun.(text)
end
