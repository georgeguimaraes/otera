# Otera お寺

Otera (お寺, "temple") renders [Jinja](https://jinja.palletsprojects.com) templates in pure Elixir. It has no native code and no dependencies.

The first goal is the chat templates of Hugging Face models. Otera renders them like `apply_chat_template` of Python transformers, byte for byte. The tests compare Otera with Python Jinja2 on 112 chat templates and on the core semantics of Jinja2.

The name follows Jinja, which got its name because "temple" sounds like "template". Jinja (神社) is a Shinto shrine. Otera (お寺) is a Buddhist temple.

Add it to your dependencies:

```elixir
{:otera, "~> 0.1"}
```

## Usage

```elixir
Otera.render("Hello {{ name }}!", %{name: "World"})
#=> {:ok, "Hello World!"}
```

Parse a template once to render it many times:

```elixir
{:ok, template} = Otera.parse(source, trim_blocks: true, lstrip_blocks: true)
Otera.render(template, %{messages: messages})
```

`Otera.render/3` returns `{:error, exception}` with an `Otera.SyntaxError` for an error in the template syntax, and an `Otera.Error` for an error during the render. The `kind` of an `Otera.Error` names the Python exception, for example `:undefined_error` or `:type_error`, and the message is the message of Jinja2. Both errors give the `line` of the template where the error happened. For an error during the render, the line follows the template traceback of Jinja2: an error in a macro gives the line in the macro.

Custom filters, tests and functions are Elixir functions:

```elixir
Otera.render("{{ name|shout }}", %{name: "otera"}, filters: %{"shout" => &String.upcase/1})
#=> {:ok, "OTERA"}
```

A plain Elixir function gets the positional arguments of the call. For keyword arguments and defaults, give an `Otera.Function`, which binds the arguments to a Python signature:

```elixir
shout = Otera.Function.new("shout", ["value", {"times", 1}], fn value, times -> value <> String.duplicate("!", times) end)
Otera.render("{{ 'hi'|shout(times=2) }}", %{}, filters: %{"shout" => shout})
#=> {:ok, "hi!!"}
```

## Autoescape

With the `autoescape` option, Otera escapes the HTML characters in the output of each `{{ ... }}`, like Jinja2. The `safe` filter marks a string as safe, and an `Otera.Markup` in the variables is safe too:

```elixir
Otera.render("{{ comment }} {{ link|safe }}", %{comment: "<script>", link: "<a href='/'>Home</a>"}, autoescape: true)
#=> {:ok, "&lt;script&gt; <a href='/'>Home</a>"}
```

`autoescape` can also be a function that gets the name of the template, for example to escape only the templates that end with `.html`. The tag `{% autoescape false %}` turns the escaping off in a part of a template.

## Inheritance, includes and imports

Give a loader to use the tags `extends`, `include`, `import` and `from`. A loader is a map from names to sources, a function, or `Otera.Loader.file_system/1`, which reads the templates from directories:

```elixir
loader = %{
  "base.html" => "<title>{% block title %}Site{% endblock %}</title>{% block body %}{% endblock %}",
  "macros.html" => "{% macro link(url, text) %}<a href=\"{{ url }}\">{{ text }}</a>{% endmacro %}"
}

page = """
{% extends "base.html" %}
{% from "macros.html" import link %}
{% block title %}Docs | {{ super() }}{% endblock %}
{% block body %}{{ link("/docs", "Read the docs") }}{% endblock %}
"""

Otera.render(page, %{}, loader: loader)
#=> {:ok, "<title>Docs | Site</title><a href=\"/docs\">Read the docs</a>"}
```

`Otera.load/2` loads a template by name, like `get_template` of Jinja2:

```elixir
{:ok, template} = Otera.load("page.html", loader: Otera.Loader.file_system("templates"), autoescape: true)
Otera.render(template, %{user: user})
```

Blocks support `super()`, `self.name()`, `scoped` and `required`. An include can take a list of names, `ignore missing`, and `with context` or `without context`. An import is without context by default, like in Jinja2.

During a render, Otera loads and parses each template once. To keep the parsed templates for many renders, like the cache of a Jinja2 `Environment`, start an `Otera.Cache` in your supervision tree and give its name with the `:cache` option:

```elixir
children = [{Otera.Cache, name: MyApp.Templates}]

opts = [loader: Otera.Loader.file_system("priv/templates"), cache: MyApp.Templates]
{:ok, template} = Otera.load("page.html", opts)
Otera.render(template, %{title: "Home"}, opts)
```

Like the auto reload of Jinja2, the cache loads a file again when its modification time or size changes, and a template of a map again when the map has another source for its name. A template of a function stays until `Otera.Cache.clear/1`, unless the function gives an `uptodate` function with the source. For a page with an extends tag and two includes, the cache makes a render about five times faster.

## Chat templates

`Otera.ChatTemplate` renders a chat template with the environment of transformers: `trim_blocks`, `lstrip_blocks`, the functions `raise_exception` and `strftime_now`, and the `tojson` filter of transformers.

```elixir
Otera.ChatTemplate.render(template, messages,
  add_generation_prompt: true,
  tools: tools,
  variables: %{bos_token: "<|begin_of_text|>", enable_thinking: false}
)
```

It also supports `continue_final_message`, which ends the prompt inside the final message, and `documents`.

`strftime_now` formats the current local time. To get the same prompt every time, give a fixed time to `Otera.ChatTemplate.options/1` and parse the template with these options:

```elixir
{:ok, template} = Otera.parse(source, Otera.ChatTemplate.options(now: ~N[2025-03-09 14:30:05]))
Otera.ChatTemplate.render(template, messages, add_generation_prompt: true)
```

## Key order

`tojson` and the iteration over a dict give the keys in order. Python dicts keep the insertion order, but Elixir maps do not. Otera uses these rules:

* A plain Elixir map gives its keys in sorted order.
* An `Otera.Dict` keeps the order of its keys: `Otera.Dict.new([{"role", "user"}, {"content", "Hi"}])`.
* `Otera.JSON.decode!/1` decodes JSON objects into `Otera.Dict` structs with the key order of the JSON text, like `json.loads`.

To get the same prompt as transformers for messages and tool definitions that come from JSON, decode them with `Otera.JSON.decode!/1`.

## Compatibility

Otera follows Python Jinja2 3.1: the lexer and its whitespace control, the operators and their precedence, scoping, macros and call blocks, loops with `loop` and `break` and `continue`, namespaces, template inheritance, includes and imports, autoescape and the `Markup` of markupsafe, the builtin filters and tests, and the Python methods of strings, lists and dicts. Values print like Python values, for example `True`, `None`, `['a', 1.5]` and `range(0, 3)`. Like transformers, Otera renders in the immutable sandbox of Jinja2, so `list.append` and `dict.update` raise a security error.

Scoping follows the compiler of Jinja2. A macro reads the variables around its definition as they are when it runs, like a Python closure. A generator, such as the result of `map` or `select`, is lazy and makes a single pass, like in Python: it does its work when the template takes its items. A loop that reads a variable before a later top-level `{% set %}` of that variable sees it as undefined, like in Jinja2.

Known differences from Python:

* Elixir floats have no inf, nan or complex values. Where Python gives one of them, Otera raises an `Otera.Error` with the kind `:not_implemented_error`. Where Python raises an `OverflowError`, Otera raises one too.
* An Elixir string cannot hold a lone surrogate such as `\ud800`, and Otera has no table of Unicode character names for `\N{...}` escapes.
* Otera values have no identity, so `x is sameas y` compares two equal lists or dicts as the same object.
* `break` outside a loop raises an `Otera.SyntaxError` instead of a Python `SyntaxError`.
* Python prints functions, generators and some other objects with their memory address, and Otera prints them without one.
* A filter block whose filter gives a value that is not a string, such as `{% filter length %}`, prints the value. Python raises a `TypeError` when it joins the output of the template, without a template line.
* A template that recurses without end raises an `Otera.Error` with the kind `:recursion_error` and the message `maximum recursion depth exceeded`. Python adds words to the message that depend on the frame where it stops. Otera counts a macro call as five Python frames and a template as one, so it stops at about the same depth as Python, which allows about 200 nested macro calls.
* The character properties come from the pinned Python, but upper and lower case mappings come from Elixir and Erlang/OTP, whose Unicode version can be newer.

## Tests

The tests compare Otera with Python Jinja2. The scripts in `scripts/` make the expected results with [uv](https://docs.astral.sh/uv/):

* `fetch_chat_templates.py` fetches the chat templates of the most downloaded text-generation models of the Hugging Face Hub into `test/fixtures/chat_templates`.
* `generate_chat_expected.py` renders each template with each conversation of `test/fixtures/conversations.json` with transformers, and writes `test/fixtures/chat_expected`.
* `generate_semantics_expected.py` renders the cases of `test/fixtures/semantics` with Python Jinja2. Some cases come from the tests of [minijinja](https://github.com/mitsuhiko/minijinja). A case can give other templates for `extends`, `include` and `import` in its settings, or use the templates of `test/fixtures/templates` with a `FileSystemLoader`. The script also renders the 2995 random templates of `test/fixtures/differential`, which `import_differential_cases.py` took from a differential check of Otera against Jinja2.
* `generate_html_entities.py` writes the HTML5 character references of Python to `priv/html_entities.json`, for the `striptags` filter.
* `generate_unicode_properties.py` writes the character properties of Python `str` methods, such as `isprintable` and `isdigit`, to `priv/unicode_properties.json` as code point ranges.

`scripts/pyproject.toml` and `scripts/uv.lock` pin the versions of Python, Jinja2 and transformers. To make the fixtures again, run these commands from the root of the repository:

```sh
uv run --project scripts python -I scripts/fetch_chat_templates.py
uv run --project scripts python -I scripts/generate_chat_expected.py
uv run --project scripts python -I scripts/generate_semantics_expected.py
uv run --project scripts python -I scripts/generate_html_entities.py
uv run --project scripts python -I scripts/generate_unicode_properties.py
```

The first command changes the corpus. Run it only when you want the new templates of the Hub. Set `HF_TOKEN` to fetch the gated repositories instead of their public mirrors.

CI tracks the Python reference:

* Dependabot opens a PR when Jinja2 or transformers has a new version.
* The workflow `reference.yml` runs on each PR that changes `scripts/`, `test/fixtures/` or `priv/`. It makes the fixtures again with the locked versions and runs the tests. It fails when the fixtures change. Then run the last four commands and commit the changes in `test/fixtures` and `priv`.
* Each Monday, `reference.yml` fetches the chat templates of the Hub again. When the corpus changes, it opens or updates the PR "test: Refresh the chat template corpus".

A red PR shows that Python changed its behavior, or that Otera does not render a new template like Python.

## License

Apache-2.0
