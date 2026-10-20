# Otera

Otera (お寺, "temple") renders [Jinja](https://jinja.palletsprojects.com) templates in pure Elixir. It has no native code and no dependencies.

The first goal is the chat templates of Hugging Face models. Otera renders them like `apply_chat_template` of Python transformers, byte for byte. The tests compare Otera with Python Jinja2 on 112 chat templates and on the core semantics of Jinja2.

The name follows Jinja. Jinja (神社) is a Japanese shrine, and a temple holds templates.

Otera is in development and is not on Hex yet.

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

`Otera.render/3` returns `{:error, exception}` with an `Otera.SyntaxError` for an error in the template syntax, and an `Otera.Error` for an error during the render. The `kind` of an `Otera.Error` names the Python exception, for example `:undefined_error` or `:type_error`, and the message is the message of Jinja2.

Custom filters, tests and functions are Elixir functions:

```elixir
Otera.render("{{ name|shout }}", %{name: "otera"}, filters: %{"shout" => &String.upcase/1})
#=> {:ok, "OTERA"}
```

A function gets the positional arguments of the call. When it takes one more argument, it also gets the keyword arguments as a map with string keys.

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

Otera follows Python Jinja2 3.1: the lexer and its whitespace control, the operators and their precedence, scoping, macros and call blocks, loops with `loop` and `break` and `continue`, namespaces, the builtin filters and tests, and the Python methods of strings, lists and dicts. Values print like Python values, for example `True`, `None` and `['a', 1.5]`. Like transformers, Otera renders in the immutable sandbox of Jinja2, so `list.append` and `dict.update` raise a security error.

These features are not in Otera yet:

* The tags `extends`, `block`, `include`, `import` and `autoescape`. Without autoescape, `safe` gives a plain string.
* The filters `filesizeformat`, `groupby`, `pprint`, `random`, `striptags`, `urlencode`, `wordwrap` and `xmlattr`, and the functions `lipsum`, `cycler` and `joiner`.

Known differences from Python:

* Elixir floats have no inf, nan or complex values. Where Python gives one of them, Otera raises an `Otera.Error`.
* `range()` gives a list, so it prints as a list.
* Otera does not model the single pass of a Python generator, such as the result of `map` or `select`.
* A macro that a template defines inside a loop reads the variables of the loop as they were when the template defined it.
* Some rare parts of Python strings are missing: bytes and `str.encode`, `\N{...}` escapes, the Unicode digits that are not decimal digits in `isdigit` and `isnumeric`, and the escapes of unassigned code points in `repr()`.
* A wrong number of arguments to a method of a string or a dict raises a `TypeError` with another message than Python, and `break` outside a loop raises an `Otera.SyntaxError` instead of a Python `SyntaxError`.
* Python prints functions and generators with their memory address, and Otera prints them without one.

## Tests

The tests compare Otera with Python Jinja2. The scripts in `scripts/` make the expected results with [uv](https://docs.astral.sh/uv/):

* `fetch_chat_templates.py` fetches the chat templates of the most downloaded text-generation models of the Hugging Face Hub into `test/fixtures/chat_templates`.
* `generate_chat_expected.py` renders each template with each conversation of `test/fixtures/conversations.json` with transformers, and writes `test/fixtures/chat_expected`.
* `generate_semantics_expected.py` renders the cases of `test/fixtures/semantics` with Python Jinja2. Some cases come from the tests of [minijinja](https://github.com/mitsuhiko/minijinja).

## License

Apache-2.0
