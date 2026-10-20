defmodule Otera.Differential do
  @moduledoc """
  Compares Otera results with the results of Python Jinja2 that the scripts in `scripts/` recorded.

  An expected result is `%{"output" => string}`, or `%{"error" => %{"type" => python_class, "message" => message, "line" => line, "name" => template}}`, where the line and the name of the template are optional.
  """

  @doc """
  Runs `fun` and returns `nil` when its result matches `expected`, or a message that shows the first difference.
  """
  def mismatch(fun, expected), do: compare(run(fun), Map.new(expected.pairs))

  defp run(fun) do
    fun.()
  rescue
    exception -> {:crash, Exception.format(:error, exception, __STACKTRACE__)}
  end

  defp compare({:crash, report}, _expected), do: "crashed: " <> report
  defp compare({:ok, output}, %{"output" => output}), do: nil
  defp compare({:ok, output}, %{"output" => wanted}), do: difference(wanted, output)

  defp compare({:ok, output}, %{"error" => wanted}),
    do: "expected #{describe_python(wanted)}\n  got output: #{inspect(output)}"

  defp compare({:error, error}, %{"output" => output}),
    do: "expected output #{inspect(output)}\n  got #{describe(error)}"

  defp compare({:error, error}, %{"error" => wanted}) do
    if describe(error) == describe_python(wanted),
      do: nil,
      else: "expected #{describe_python(wanted)}\n  got #{describe(error)}"
  end

  defp describe(error),
    do: "#{error_kind(error)} at #{position(error.line, error.name)}: #{error.message}"

  defp describe_python(wanted) do
    wanted = Map.new(wanted.pairs)

    "#{python_kind(wanted["type"])} at #{position(wanted["line"], wanted["name"])}: #{wanted["message"]}"
  end

  defp position(line, nil), do: "line #{line}"
  defp position(line, name), do: "line #{line} of #{name}"

  # Otera raises Otera.SyntaxError for both compile-time errors of Jinja2.
  defp python_kind("TemplateAssertionError"), do: "template_syntax_error"
  defp python_kind(type), do: Macro.underscore(type)

  defp error_kind(%Otera.SyntaxError{}), do: "template_syntax_error"
  defp error_kind(%Otera.Error{kind: kind}), do: Atom.to_string(kind)

  defp difference(expected, actual) do
    position = common_prefix(expected, actual, 0)
    start = max(position - 60, 0)

    "outputs differ at byte #{position}\n  expected: #{context(expected, start)}\n  actual:   #{context(actual, start)}"
  end

  defp common_prefix(<<char, left::binary>>, <<char, right::binary>>, count),
    do: common_prefix(left, right, count + 1)

  defp common_prefix(_left, _right, count), do: count

  defp context(string, start) do
    size = min(120, max(byte_size(string) - start, 0))
    string |> binary_part(min(start, byte_size(string)), size) |> inspect()
  end
end

ExUnit.start()
