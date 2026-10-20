defmodule Otera.SemanticsTest do
  use ExUnit.Case, async: true

  alias Otera.{Dict, Differential, JSON}

  @cases Path.expand("../fixtures/semantics", __DIR__)
  @differential Path.expand("../fixtures/differential", __DIR__)

  test "renders the core semantics cases like Python Jinja2" do
    expected = read_json(Path.join(@cases, "expected.json"))

    failures =
      for {name, wanted} <- expected.pairs,
          message = Differential.mismatch(fn -> render_file(name) end, wanted),
          do: "#{name}: #{message}"

    assert length(expected.pairs) == length(Path.wildcard(Path.join(@cases, "*/*.txt")))
    assert_matches(failures, expected)
  end

  test "renders the random cases of the differential check like Python Jinja2" do
    cases = read_json(Path.join(@differential, "cases.json"))
    expected = read_json(Path.join(@differential, "expected.json"))

    failures =
      for test_case <- cases,
          name = test_case["name"],
          render = fn ->
            render(
              test_case["template"],
              JSON.decode!(test_case["variables"]),
              test_case["settings"]
            )
          end,
          message = Differential.mismatch(render, expected[name]),
          do: "#{name}: #{inspect(test_case["template"])}\n  #{message}"

    assert length(cases) == length(expected.pairs)
    assert_matches(failures, expected)
  end

  defp assert_matches(failures, expected) do
    assert failures == [],
           "#{length(failures)} of #{length(expected.pairs)} cases differ from Jinja2:\n\n" <>
             Enum.join(failures, "\n\n")
  end

  defp render_file(name) do
    [variables, source] =
      @cases |> Path.join(name) |> File.read!() |> String.split("\n---\n", parts: 2)

    %Dict{pairs: pairs} = JSON.decode!(variables)
    {settings, variables} = List.keytake(pairs, "$settings", 0) || {{"$settings", %Dict{}}, pairs}
    {_, settings} = settings
    render(source, Dict.new(variables), settings)
  end

  defp render(source, variables, %Dict{pairs: [{"transformers", true}]}),
    do: Otera.render(source, variables, transformers_options())

  defp render(source, variables, %Dict{pairs: settings}) do
    options =
      Enum.map(settings, fn {key, value} -> option(String.to_existing_atom(key), value) end)

    Otera.render(source, variables, options)
  end

  # A list of extensions stands for select_autoescape of Jinja2, which escapes templates from strings.
  defp option(:autoescape, extensions) when is_list(extensions) do
    {:autoescape,
     fn
       nil -> true
       name -> Enum.any?(extensions, &String.ends_with?(String.downcase(name), "." <> &1))
     end}
  end

  defp option(key, value), do: {key, value}

  # scripts/generate_semantics_expected.py renders with this time for strftime_now.
  defp transformers_options, do: Otera.ChatTemplate.options(now: ~N[2025-03-09 14:30:05])

  defp read_json(path), do: path |> File.read!() |> JSON.decode!()
end
