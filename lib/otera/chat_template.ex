defmodule Otera.ChatTemplate do
  @moduledoc """
  Renders the chat template of a Hugging Face model like `apply_chat_template` in Python transformers.

      template = File.read!("chat_template.jinja")

      Otera.ChatTemplate.render(template, [%{role: "user", content: "Hello!"}],
        add_generation_prompt: true,
        variables: %{bos_token: "<|begin_of_text|>"}
      )
      #=> {:ok, "<|begin_of_text|><|start_header_id|>user<|end_header_id|>..."}

  `options/1` gives the environment of transformers: `trim_blocks` and `lstrip_blocks`, the `raise_exception(message)` and `strftime_now(format)` functions, and a `tojson` filter that does not escape HTML or non-ASCII characters and accepts the `ensure_ascii`, `indent`, `separators` and `sort_keys` arguments of Python `json.dumps`.

  ## Key order

  `tojson` prints the keys of a dict in order. A plain Elixir map gives its keys in sorted order, and Python gives them in insertion order. To get the output of transformers for tools or messages that come from JSON, decode the JSON with `Otera.JSON.decode!/1`, which keeps the key order of the text.
  """

  alias Otera.{Dict, Template, Value}

  # transformers marks the end of the final message with this tag to find it in the rendered prompt.
  @continue_tag "CONTINUE_FINAL_MESSAGE_TAG "

  @doc """
  Returns the options of the transformers environment, for `Otera.parse/2` and `Otera.render/3`.

  ## Options

    * `:now` - the local time that `strftime_now` formats, as a `NaiveDateTime`. By default, `strftime_now` formats the current local time.
  """
  @spec options(keyword) :: keyword
  def options(opts \\ []) do
    now = Keyword.get(opts, :now)

    [
      trim_blocks: true,
      lstrip_blocks: true,
      filters: %{"tojson" => &tojson/2},
      globals: %{
        "raise_exception" => &raise_exception/1,
        "strftime_now" => &strftime_now(&1, now || NaiveDateTime.local_now())
      }
    ]
  end

  @doc """
  Renders `messages` with a chat template, given as source or as a template that `Otera.parse/2` made with `options/0`.

  ## Options

    * `:add_generation_prompt` - ends the prompt with the start of an assistant message. The default is `false`.
    * `:continue_final_message` - ends the prompt inside the final message, so that the model continues it. `true` continues the `"content"` of the message, and a string continues the field with that name. The default is `false`.
    * `:tools` - a list of tool definitions in JSON schema form. The default is `nil`.
    * `:documents` - a list of documents for retrieval-augmented generation. The default is `nil`.
    * `:variables` - other variables of the template, such as the special tokens `bos_token` and `eos_token`, or `enable_thinking: false` for Qwen3.
  """
  @spec render(String.t() | Template.t(), list, keyword) ::
          {:ok, String.t()} | {:error, Otera.error()}
  def render(template, messages, opts \\ [])

  def render(source, messages, opts) when is_binary(source) do
    with {:ok, template} <- Otera.parse(source, options()), do: render(template, messages, opts)
  end

  def render(%Template{} = template, messages, opts) do
    messages = Value.from_elixir(messages)

    variables =
      opts
      |> Keyword.get(:variables, %{})
      |> Map.new(fn {name, value} -> {to_string(name), value} end)
      |> Map.merge(%{
        "messages" => messages,
        "tools" => Keyword.get(opts, :tools),
        "documents" => Keyword.get(opts, :documents),
        "add_generation_prompt" => Keyword.get(opts, :add_generation_prompt, false)
      })

    case Keyword.get(opts, :continue_final_message, false) do
      false -> Otera.render(template, variables)
      true -> continue_final_message(template, variables, "content")
      field when is_binary(field) -> continue_final_message(template, variables, field)
    end
  end

  @doc """
  Like `render/3`, but raises the error.
  """
  @spec render!(String.t() | Template.t(), list, keyword) :: String.t()
  def render!(template, messages, opts \\ []) do
    case render(template, messages, opts) do
      {:ok, prompt} -> prompt
      {:error, error} -> raise error
    end
  end

  defp continue_final_message(template, variables, field) do
    {final, rest} = List.pop_at(variables["messages"], -1)

    with {:ok, original, final} <- tag_final_message(final, field, template.source),
         {:ok, prompt} <- Otera.render(template, %{variables | "messages" => rest ++ [final]}) do
      cut_at_tag(prompt, original)
    end
  end

  defp tag_final_message(message, field, source) do
    value = if is_struct(message, Dict), do: Dict.fetch(message, field), else: :error

    cond do
      value in [:error, {:ok, nil}] ->
        value_error(
          ~s(continue_final_message is set but the final message has no "#{field}" to continue!)
        )

      not String.contains?(source, field) ->
        value_error(
          ~s(continue_final_message is set to "#{field}" but this is not an accepted field in the chat_template)
        )

      true ->
        {:ok, content} = value
        tag_content(message, field, content)
    end
  end

  defp tag_content(message, field, blocks) when is_list(blocks) or is_tuple(blocks) do
    blocks = Value.to_list(blocks)

    index =
      blocks
      |> Enum.reverse()
      |> Enum.find_index(&(is_struct(&1, Dict) and Dict.fetch(&1, "text") != :error))

    if index do
      position = length(blocks) - 1 - index
      block = Enum.at(blocks, position)
      {:ok, text} = Dict.fetch(block, "text")
      tagged = Dict.put(block, "text", Value.binary_op(:add, text, @continue_tag))
      {:ok, text, Dict.put(message, field, List.replace_at(blocks, position, tagged))}
    else
      value_error(
        "continue_final_message is set but we could not find any text to continue in the final message!"
      )
    end
  end

  defp tag_content(message, field, content),
    do: {:ok, content, Dict.put(message, field, Value.binary_op(:add, content, @continue_tag))}

  # As transformers: cut the prompt at the last tag. When the template trimmed the space after
  # the tag, also remove the spaces before it.
  defp cut_at_tag(prompt, original) do
    final_message = Value.strip(Value.to_str(original), nil, :both)
    tag = String.trim(@continue_tag)

    if String.contains?(prompt, final_message) and String.contains?(prompt, tag) do
      {position, _} = prompt |> :binary.matches(tag) |> List.last()
      before = binary_part(prompt, 0, position)
      rest = binary_part(prompt, position, byte_size(prompt) - position)

      {:ok,
       if(String.starts_with?(rest, @continue_tag),
         do: before,
         else: Value.strip(before, nil, :trailing)
       )}
    else
      missing_final_message(final_message, prompt)
    end
  end

  defp missing_final_message(final_message, prompt) do
    value_error(
      "continue_final_message is set but the final message does not appear in the chat after applying the chat template! This can happen if the chat template deletes portions of the final message. Please verify the chat template and final message in your chat to ensure they are compatible.Final message to continue: #{final_message}\nRendered chat:\n#{prompt}"
    )
  end

  defp value_error(message), do: {:error, %Otera.Error{kind: :value_error, message: message}}

  defp bind(kwargs, params, function) when is_map(kwargs) and not is_struct(kwargs),
    do: Otera.Methods.bind([], Dict.new(Map.to_list(kwargs)), params, function)

  defp bind(argument, params, function),
    do: Otera.Methods.bind([argument], %Dict{}, params, function)

  # These functions get either their one positional argument, or the keyword arguments as a plain
  # map, which a template value never is.
  defp raise_exception(argument) do
    [message] = bind(argument, ["message"], "raise_exception")
    raise Otera.Error, kind: :template_error, message: Value.to_str(message)
  end

  defp strftime_now(argument, now) do
    [format] = bind(argument, ["format"], "strftime_now")
    Calendar.strftime(now, format)
  end

  defp tojson(value, argument) do
    [ensure_ascii, indent, separators, sort_keys] =
      bind(
        argument,
        [{"ensure_ascii", false}, {"indent", nil}, {"separators", nil}, {"sort_keys", false}],
        "tojson"
      )

    Otera.JSON.dumps(value,
      ensure_ascii: Value.truthy?(ensure_ascii),
      indent: indent,
      separators: separators,
      sort_keys: Value.truthy?(sort_keys)
    )
  end
end
