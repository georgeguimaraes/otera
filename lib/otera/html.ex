defmodule Otera.HTML do
  @moduledoc """
  HTML text like Python: `escape/1` of markupsafe, `unescape/1` of `html.unescape`, and `striptags/1` of `Markup.striptags`.

  The character references come from `priv/html_entities.json`, which `scripts/generate_html_entities.py` writes from the HTML5 table of Python.
  """

  @external_resource Path.expand("../../priv/html_entities.json", __DIR__)
  @entities @external_resource |> File.read!() |> JSON.decode!()
  @named @entities["named"]
  @invalid_charrefs Map.new(@entities["invalid_charrefs"], fn {code, text} ->
                      {String.to_integer(code), text}
                    end)
  @invalid_codepoints MapSet.new(@entities["invalid_codepoints"])
  @longest_name @named |> Map.keys() |> Enum.map(&String.length/1) |> Enum.max()

  @doc """
  Escapes `&`, `<`, `>`, `'` and `"`, like `markupsafe.escape`.
  """
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    String.replace(text, ["&", "<", ">", "'", "\""], fn
      "&" -> "&amp;"
      "<" -> "&lt;"
      ">" -> "&gt;"
      "'" -> "&#39;"
      "\"" -> "&#34;"
    end)
  end

  @doc """
  Replaces the named and numeric character references, like `html.unescape`.
  """
  @spec unescape(String.t()) :: String.t()
  def unescape(text) do
    Regex.replace(~r/&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\t\n\f <&#;]{1,32};?)/u, text, fn _,
                                                                                         reference ->
      replace_reference(reference)
    end)
  end

  defp replace_reference("#" <> number) do
    code =
      case number do
        <<x, hex::binary>> when x in [?x, ?X] ->
          hex |> String.trim_trailing(";") |> String.to_integer(16)

        decimal ->
          decimal |> String.trim_trailing(";") |> String.to_integer()
      end

    cond do
      Map.has_key?(@invalid_charrefs, code) -> @invalid_charrefs[code]
      code in 0xD800..0xDFFF or code > 0x10FFFF -> "�"
      MapSet.member?(@invalid_codepoints, code) -> ""
      true -> <<code::utf8>>
    end
  end

  # The longest name that is a reference, as the HTML5 standard defines.
  defp replace_reference(name) do
    case @named do
      %{^name => text} ->
        text

      _ ->
        length = min(String.length(name), @longest_name + 1)

        Enum.find_value((length - 1)..2//-1, "&" <> name, fn size ->
          {prefix, rest} = String.split_at(name, size)
          if text = @named[prefix], do: text <> rest
        end)
    end
  end

  @doc """
  Removes the tags and comments of `text`, joins the whitespace into single spaces, and unescapes the references, like `Markup.striptags` of markupsafe.
  """
  @spec striptags(String.t()) :: String.t()
  def striptags(text) do
    text
    |> remove_tags([])
    |> Otera.Methods.call("split", [], %Otera.Dict{})
    |> Enum.join(" ")
    |> unescape()
  end

  defp remove_tags(text, parts) do
    with {start, _} <- :binary.match(text, "<"),
         rest = binary_part(text, start, byte_size(text) - start),
         {closer, offset} = if(String.starts_with?(rest, "<!--"), do: {"-->", 4}, else: {">", 0}),
         {end_pos, size} <- :binary.match(rest, closer, scope: {offset, byte_size(rest) - offset}) do
      after_tag = end_pos + size

      remove_tags(binary_part(rest, after_tag, byte_size(rest) - after_tag), [
        binary_part(text, 0, start) | parts
      ])
    else
      _ -> IO.iodata_to_binary(Enum.reverse([text | parts]))
    end
  end
end
