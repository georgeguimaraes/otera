defmodule Otera.Template do
  @moduledoc """
  A parsed template. `Otera.parse/2` makes it, and `Otera.render/3` renders it many times without parsing it again.

  `options` holds the options of `Otera.parse/2`, which also apply to each render.
  """

  defstruct [:source, :ast, options: []]

  @type t :: %__MODULE__{source: String.t(), ast: list, options: keyword}
end
