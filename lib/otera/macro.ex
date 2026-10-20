defmodule Otera.Macro do
  @moduledoc """
  A macro that a template defines with `{% macro %}`, or the `caller` of a `{% call %}` block, which has no name.

  `params` is a list of `{name, default_expr_or_nil}`, `special_names` lists which of `caller`, `varargs` and `kwargs` the body uses, and `frames` holds the scopes around the definition, which the body can read.
  """

  alias Otera.Undefined

  defstruct [:name, :params, :body, :special_names, :frames]

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
