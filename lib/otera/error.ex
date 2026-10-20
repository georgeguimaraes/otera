defmodule Otera.Error do
  @moduledoc """
  An error that a template raises while it renders.

  `kind` names the Python exception that Jinja2 raises in the same case, in snake case: `:template_error` for `raise_exception`, `:undefined_error` for an operation on an undefined value, `:type_error`, `:value_error`, `:security_error` for a sandbox violation, and others. `message` is the message of the Python exception.

  `line` is the line of the template where the error happened, and `name` is the name of that template, `nil` for a template that `Otera.parse/2` made from a string. They follow the template traceback of Jinja2: an error in a macro gives the line in the macro.
  """

  defexception [:kind, :message, :line, :name]

  @impl true
  def message(%{message: message, line: nil}), do: message
  def message(%{message: message, line: line, name: nil}), do: "#{message} (line #{line})"

  def message(%{message: message, line: line, name: name}),
    do: "#{message} (#{name}, line #{line})"
end
