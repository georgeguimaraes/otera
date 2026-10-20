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

  test "a plain function takes positional arguments, and an Otera.Function binds keyword arguments" do
    shout = fn name, times -> String.duplicate("!", times) <> name end

    globals = %{
      "greet" => fn name -> "hello " <> name end,
      "shout" => Otera.Function.new("shout", ["name", {"times", 1}], shout)
    }

    cases = [
      {"positional", "{{ greet('a') }}", {:ok, "hello a"}},
      {"default", "{{ shout('a') }}", {:ok, "!a"}},
      {"keyword", "{{ shout('a', times=3) }}", {:ok, "!!!a"}},
      {"filter", "{{ 'a'|shout(times=2) }}", {:ok, "!!a"}},
      {"missing", "{{ shout() }}",
       {:error,
        %Otera.Error{
          kind: :type_error,
          message: "shout() missing 1 required positional argument: 'name'"
        }}}
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

    assert {:error, %Otera.Error{kind: :type_error}} =
             Otera.render("{{ greet('a', 'b') }}", %{}, globals: globals)
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

  # Python gives random output for these, so the test checks only its shape.
  test "random picks an item and lipsum makes paragraphs of lorem ipsum" do
    {:ok, item} = Otera.render("{{ ['a', 'b', 'c']|random }}")
    assert item in ["a", "b", "c"]
    assert Otera.render("{{ []|random is undefined }}") == {:ok, "True"}

    {:ok, html} = Otera.render("{{ lipsum() }}")
    assert length(String.split(html, "\n")) == 5

    assert Enum.all?(String.split(html, "\n"), &(&1 =~ ~r/\A<p>[A-Z][^<]*\.<\/p>\z/))

    {:ok, text} = Otera.render("{{ lipsum(2, false, 3, 6) }}")
    [first, second] = String.split(text, "\n\n")
    for paragraph <- [first, second], do: assert(length(String.split(paragraph)) in 3..5)
  end
end
