defmodule Otera.SemanticsTest do
  use ExUnit.Case, async: true

  alias Otera.{Dict, Differential, JSON}

  @cases Path.expand("../fixtures/semantics", __DIR__)

  test "renders the core semantics cases like Python Jinja2" do
    expected = @cases |> Path.join("expected.json") |> File.read!() |> JSON.decode!()

    failures =
      for {name, wanted} <- expected.pairs,
          message = Differential.mismatch(fn -> render(name) end, wanted),
          do: "#{name}: #{message}"

    assert length(expected.pairs) == length(Path.wildcard(Path.join(@cases, "*/*.txt")))

    assert failures == [],
           "#{length(failures)} of #{length(expected.pairs)} cases differ from Jinja2:\n\n" <>
             Enum.join(failures, "\n\n")
  end

  defp render(name) do
    [variables, source] =
      @cases |> Path.join(name) |> File.read!() |> String.split("\n---\n", parts: 2)

    %Dict{pairs: pairs} = JSON.decode!(variables)
    {settings, variables} = List.keytake(pairs, "$settings", 0) || {{"$settings", %Dict{}}, pairs}
    {_, %Dict{pairs: settings}} = settings

    options =
      case settings do
        [{"transformers", true}] ->
          transformers_options()

        settings ->
          Enum.map(settings, fn {key, value} -> {String.to_existing_atom(key), value} end)
      end

    Otera.render(source, Dict.new(variables), options)
  end

  # scripts/generate_semantics_expected.py renders with this time for strftime_now.
  defp transformers_options, do: Otera.ChatTemplate.options(now: ~N[2025-03-09 14:30:05])
end
