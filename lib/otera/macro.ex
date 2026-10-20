defmodule Otera.Macro do
  @moduledoc """
  A macro that a template defines with `{% macro %}`, or the `caller` of a `{% call %}` block, which has no name.

  `params` is a list of `{name, default_expr_or_nil}`, `special_names` lists which of `caller`, `varargs` and `kwargs` the body uses, `frames` holds the scopes around the definition, which the body reads as they are at call time, `scope` is the scope of the body from `Otera.Scope`, `line` is the line of the definition, where Jinja2 evaluates the default values, `escape` is the autoescape of the definition, which the body uses for its outputs, and `template` is the name of the template that defines the macro.
  """

  alias Otera.Undefined

  defstruct [
    :name,
    :params,
    :body,
    :special_names,
    :frames,
    :scope,
    :line,
    :template,
    escape: false
  ]

  @doc """
  Returns the attribute `name` of `macro`, like the Python `Macro` object of Jinja2.
  """
  @spec get(%__MODULE__{}, String.t()) :: term
  def get(macro, "name"), do: macro.name
  def get(macro, "arguments"), do: macro.params |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
  def get(macro, "caller"), do: "caller" in macro.special_names
  def get(macro, "catch_kwargs"), do: "kwargs" in macro.special_names
  def get(macro, "catch_varargs"), do: "varargs" in macro.special_names
  def get(macro, name), do: %Undefined{obj: macro, name: name}
end
