defmodule Otera.TemplateReference do
  @moduledoc """
  The `self` variable of a template, like the `TemplateReference` of Jinja2. `self.name` is the block `name`, as an `Otera.BlockReference`.
  """

  defstruct [:context, :name]

  @type t :: %__MODULE__{context: reference, name: String.t() | nil}
end
