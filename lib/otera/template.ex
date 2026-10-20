defmodule Otera.Template do
  @moduledoc """
  A parsed template. `Otera.parse/2` makes it, and `Otera.render/3` renders it many times without parsing it again.

  `options` holds the options of `Otera.parse/2`, which also apply to each render, and `scope` is the root scope from `Otera.Scope`.
  """

  defstruct [:source, :ast, :scope, options: []]

  @type t :: %__MODULE__{source: String.t(), ast: list, scope: Otera.Scope.t(), options: keyword}
end
