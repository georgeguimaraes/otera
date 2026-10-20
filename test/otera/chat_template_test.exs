defmodule Otera.ChatTemplateTest do
  use ExUnit.Case, async: true

  alias Otera.{ChatTemplate, Dict, Differential, JSON}

  @fixtures Path.expand("../fixtures", __DIR__)
  # scripts/generate_chat_expected.py renders with this time for strftime_now.
  @now ~N[2025-03-09 14:30:05]

  test "renders the corpus of chat templates like transformers" do
    manifest = read_json("chat_templates/manifest.json")
    conversations = read_json("conversations.json")

    options = ChatTemplate.options(now: @now)

    results =
      Enum.flat_map(manifest, fn entry ->
        name = field(entry, "name")
        source = File.read!(Path.join([@fixtures, "chat_templates", name <> ".jinja"]))
        {:ok, template} = Otera.parse(source, options)
        expected = read_json("chat_expected/#{name}.json")

        for conversation <- conversations do
          case_name = field(conversation, "name")
          messages = field(conversation, "messages")

          render = fn ->
            ChatTemplate.render(template, messages, render_options(conversation, entry))
          end

          {"#{name} / #{case_name}", Differential.mismatch(render, field(expected, case_name))}
        end
      end)

    assert length(results) == length(manifest) * length(conversations)
    failures = for {name, message} <- results, message, do: "#{name}: #{message}"

    assert failures == [],
           "#{length(failures)} of #{length(results)} cases differ from transformers:\n\n" <>
             Enum.join(failures, "\n\n")
  end

  defp render_options(conversation, entry) do
    variables =
      Map.merge(
        Map.new(field(entry, "special_tokens").pairs),
        Map.new((field(conversation, "variables") || %Dict{}).pairs)
      )

    [
      add_generation_prompt: field(conversation, "add_generation_prompt"),
      continue_final_message: field(conversation, "continue_final_message") || false,
      tools: field(conversation, "tools"),
      documents: field(conversation, "documents"),
      variables: variables
    ]
  end

  defp field(dict, key) do
    case Dict.fetch(dict, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp read_json(path), do: @fixtures |> Path.join(path) |> File.read!() |> JSON.decode!()
end
