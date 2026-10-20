defmodule Otera.SyntaxError do
  @moduledoc """
  An error in the syntax of a template, with the line where Otera found it.

  `message` is the message that Python Jinja2 gives for the same error. `name` is the name of the template, or `nil` for a template from a string without a name.
  """

  defexception [:message, :line, :name]

  @impl true
  def message(%{message: message, line: line, name: nil}), do: "#{message} (line #{line})"

  def message(%{message: message, line: line, name: name}),
    do: "#{message} (#{name}, line #{line})"
end
