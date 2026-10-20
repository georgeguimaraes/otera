defmodule Otera.Error do
  @moduledoc """
  An error that a template raises while it renders.

  `kind` names the Python exception that Jinja2 raises in the same case, in snake case: `:template_error` for `raise_exception`, `:undefined_error` for an operation on an undefined value, `:type_error`, `:value_error`, `:security_error` for a sandbox violation, and others. `message` is the message of the Python exception.
  """

  defexception [:kind, :message]
end
