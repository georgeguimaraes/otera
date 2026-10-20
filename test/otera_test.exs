defmodule OteraTest do
  use ExUnit.Case, async: true

  doctest Otera
  doctest Otera.JSON

  test "dicts keep the key order of Otera.Dict and decoded JSON, and sort the keys of maps" do
    template =
      "{% for key, value in tool.items() %}{{ key }}={{ value }} {% endfor %}{{ tool|tojson }}"

    cases = [
      {"map", %{1 => "one", name: "f", description: "d"},
       ~s(1=one description=d name=f {"1": "one", "description": "d", "name": "f"})},
      {"dict", Otera.Dict.new(name: "f", description: "d"),
       ~s(name=f description=d {"name": "f", "description": "d"})},
      {"json", Otera.JSON.decode!(~s({"name": "f", "description": "d"})),
       ~s(name=f description=d {"name": "f", "description": "d"})}
    ]

    for {name, tool, expected} <- cases do
      assert Otera.render(template, %{tool: tool}, Otera.ChatTemplate.options()) ==
               {:ok, expected},
             name
    end
  end

  test "functions get keyword arguments as a map when they take one more argument" do
    globals = %{
      "greet" => fn name -> "hello " <> name end,
      "shout" => fn name, opts -> String.duplicate("!", opts["times"] || 1) <> name end
    }

    cases = [
      {"positional", "{{ greet('a') }}", {:ok, "hello a"}},
      {"no keywords", "{{ shout('a') }}", {:ok, "!a"}},
      {"keywords", "{{ shout('a', times=3) }}", {:ok, "!!!a"}},
      {"filter", "{{ 'a'|shout(times=2) }}", {:ok, "!!a"}}
    ]

    for {name, template, expected} <- cases do
      assert Otera.render(template, %{},
               globals: globals,
               filters: %{"shout" => globals["shout"]}
             ) == expected,
             name
    end

    assert {:error, %Otera.Error{kind: :type_error}} =
             Otera.render("{{ greet('a', b=1) }}", %{}, globals: globals)
  end

  test "a parsed template keeps its options, and render options add to them" do
    {:ok, template} =
      Otera.parse("{%- if true %}\n{{ a() }}|{{ x|twice }}{% endif %}",
        trim_blocks: true,
        filters: %{twice: &(&1 <> &1)},
        globals: %{a: fn -> 1 end}
      )

    assert Otera.render(template, %{x: "y"}) == {:ok, "1|yy"}
    assert Otera.render(template, %{x: "y"}, globals: %{a: fn -> 2 end}) == {:ok, "2|yy"}

    assert Otera.render("{{ x|twice }}", %{x: "y"}) ==
             {:error, %Otera.SyntaxError{message: "No filter named 'twice'.", line: 1}}
  end
end
