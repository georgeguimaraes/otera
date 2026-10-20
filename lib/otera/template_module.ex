defmodule Otera.TemplateModule do
  @moduledoc """
  A template that `{% import %}` loaded, like the `TemplateModule` of Jinja2.

  `exports` holds the macros and the top-level variables of the template whose names do not start with `_`. `body` is the output of the template, which prints when a template prints the module.
  """

  alias Otera.Undefined

  defstruct [:name, :body, exports: %{}]

  @type t :: %__MODULE__{name: String.t() | nil, body: String.t(), exports: map}

  @doc """
  Returns the export `name` of `module`, or an undefined value.
  """
  @spec get(t, String.t()) :: term
  def get(module, name) do
    case module.exports do
      %{^name => value} -> value
      _ -> %Undefined{obj: module, name: name}
    end
  end
end
