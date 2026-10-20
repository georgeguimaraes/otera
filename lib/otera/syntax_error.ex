defmodule Otera.SyntaxError do
  @moduledoc """
  An error in the syntax of a template, with the line where Otera found it.

  `message` is the message that Python Jinja2 gives for the same error.
  """

  defexception [:message, :line]

  @impl true
  def message(%{message: message, line: line}), do: "#{message} (line #{line})"
end
