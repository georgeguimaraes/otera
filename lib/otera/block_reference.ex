defmodule Otera.BlockReference do
  @moduledoc """
  A block that a template can render: `super()` in a block, or `self.name()`, like the `BlockReference` of Jinja2.

  `context` is the context of the render, `name` is the name of the block, and `depth` is the position in the chain of blocks of that name: 0 for the block of the child template, 1 for the block of its parent, and so on.
  """

  defstruct [:context, :name, :depth]

  @type t :: %__MODULE__{context: reference, name: String.t(), depth: non_neg_integer}
end
