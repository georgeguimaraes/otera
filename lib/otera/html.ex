defmodule Otera.HTML do
  @moduledoc """
  HTML text like Python: `escape/1` of markupsafe, `unescape/1` of `html.unescape`, `striptags/1` of `Markup.striptags`, and `urlize/5` of Jinja2.

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

  # The regular expressions of jinja2.utils. They run on the skeleton of a word, in which each
  # character that is not ASCII stands for its class in Python, so that \w, \d and [a-z] with
  # IGNORECASE match like the re module of Python.
  @http ~r/\A(?:(?:https?:\/\/|www\.)(?:[\w%-]+\.)*(?:[a-z]{2,63}|xn--[\w%]{2,59})|(?:[\w%-]{2,63}\.)+(?:com|net|int|edu|gov|org|info|mil)|https?:\/\/(?:\d{1,3}(?:\.\d{1,3}){3}|\[(?:[\da-f]{0,4}:){2}(?:[\da-f]{0,4}:?){1,6}\]))(?::\d{1,5})?(?:[\/?#].*)?\z/is
  @email ~r/\A.+@\w[\w.-]*\.\w+\z/s
  @scheme ~r/\A[\w.+-]{2,}:\/{0,2}\z/
  @head ~r/\A(?:[(<]|&lt;)+/
  @tail ~r/(?:[)>.,\n]|&gt;)+\z/

  @doc """
  Converts the URLs and email addresses in `text` into links, like `urlize` of `jinja2.utils`.

  `text` is a string or an `Otera.Markup`, which the function escapes like `markupsafe.escape`. `trim_url_limit` shortens the text of a link, `rel` and `target` add their attributes, and `extra_schemes` is a list of more schemes to link, or `nil`.
  """
  @spec urlize(term, term, String.t() | nil, term, [String.t()] | nil) :: String.t()
  def urlize(text, trim_url_limit, rel, target, extra_schemes) do
    rel_attr = if rel in [nil, ""], do: "", else: ~s( rel="#{escape(rel)}")

    target_attr =
      if Otera.Value.truthy?(target),
        do: ~s( target="#{Otera.Markup.escape(target).text}"),
        else: ""

    link = %{trim: trim_url_limit, attrs: rel_attr <> target_attr, schemes: extra_schemes}

    text
    |> Otera.Markup.escape()
    |> Map.fetch!(:text)
    |> split_words([], [])
    |> Enum.map_join(fn
      {:space, space} -> space
      {:word, word} -> urlize_word(word, link)
    end)
  end

  @doc """
  Returns true if `scheme` is a URI scheme prefix that the `urlize` filter accepts, such as `ftp:`.
  """
  @spec scheme?(String.t()) :: boolean
  def scheme?(scheme), do: Regex.match?(@scheme, skeleton(scheme))

  # re.split(r"(\s+)", text) of Python, with the whitespace of str.isspace.
  defp split_words("", chars, parts), do: Enum.reverse(add_part(chars, parts))

  defp split_words(<<char::utf8, rest::binary>>, chars, parts) do
    type = if Otera.Unicode.space?(char), do: :space, else: :word

    case chars do
      {^type, acc} -> split_words(rest, {type, [<<char::utf8>> | acc]}, parts)
      _ -> split_words(rest, {type, [<<char::utf8>>]}, add_part(chars, parts))
    end
  end

  defp add_part({type, acc}, parts),
    do: [{type, acc |> Enum.reverse() |> IO.iodata_to_binary()} | parts]

  defp add_part(_none, parts), do: parts

  defp urlize_word(word, link) do
    {head, middle} =
      case Regex.run(@head, word) do
        [head] -> {head, binary_part(word, byte_size(head), byte_size(word) - byte_size(head))}
        nil -> {"", word}
      end

    {middle, tail} =
      with true <- String.ends_with?(middle, [")", ">", ".", ",", "\n", "&gt;"]),
           [{start, _}] <- Regex.run(@tail, middle, return: :index) do
        {binary_part(middle, 0, start), binary_part(middle, start, byte_size(middle) - start)}
      else
        _ -> {middle, ""}
      end

    {middle, tail} =
      Enum.reduce([{"(", ")"}, {"<", ">"}, {"&lt;", "&gt;"}], {middle, tail}, &balance/2)

    head <> link(middle, link) <> tail
  end

  # Moves end characters from the tail to the middle while the middle has more start characters.
  defp balance({start_char, end_char}, {middle, tail}) do
    start_count = count(middle, start_char)

    if start_count <= count(middle, end_char) do
      {middle, tail}
    else
      Enum.reduce(1..min(start_count, count(tail, end_char))//1, {middle, tail}, fn _,
                                                                                    {middle, tail} ->
        {index, size} = :binary.match(tail, end_char)
        end_index = index + size

        {middle <> binary_part(tail, 0, end_index),
         binary_part(tail, end_index, byte_size(tail) - end_index)}
      end)
    end
  end

  defp count(text, pattern), do: text |> :binary.matches(pattern) |> length()

  defp link(middle, link) do
    skeleton = skeleton(middle)

    cond do
      Regex.match?(@http, skeleton) ->
        href =
          if String.starts_with?(middle, ["https://", "http://"]),
            do: middle,
            else: "https://" <> middle

        ~s(<a href="#{href}"#{link.attrs}>#{trim_url(middle, link.trim)}</a>)

      String.starts_with?(middle, "mailto:") and
          Regex.match?(@email, binary_part(skeleton, 7, byte_size(skeleton) - 7)) ->
        ~s(<a href="#{middle}">#{binary_part(middle, 7, byte_size(middle) - 7)}</a>)

      String.contains?(middle, "@") and not String.starts_with?(middle, ["www.", "@"]) and
        not String.contains?(middle, ":") and Regex.match?(@email, skeleton) ->
        ~s(<a href="mailto:#{middle}">#{middle}</a>)

      true ->
        # Like Jinja2, each scheme tests the middle as the scheme before it left it.
        Enum.reduce(link.schemes || [], middle, fn scheme, middle ->
          if middle != scheme and String.starts_with?(middle, scheme),
            do: ~s(<a href="#{middle}"#{link.attrs}>#{middle}</a>),
            else: middle
        end)
    end
  end

  defp trim_url(url, nil), do: url

  defp trim_url(url, limit) do
    if Otera.Value.compare(:gt, Otera.Value.str_length(url), limit),
      do: Otera.Value.slice(url, nil, limit, nil) <> "...",
      else: url
  end

  defp skeleton(text), do: for(<<char::utf8 <- text>>, into: "", do: stand_in(char))

  defp stand_in(char) when char < 128, do: <<char>>

  defp stand_in(char) do
    cond do
      Otera.Unicode.decimal?(char) ->
        "0"

      letter = ascii_letter(<<char::utf8>>) ->
        letter

      Otera.Unicode.alpha?(char) or Otera.Unicode.digit?(char) or Otera.Unicode.numeric?(char) ->
        "_"

      true ->
        <<1>>
    end
  end

  # A letter such as the Kelvin sign or the long s matches [a-z] with IGNORECASE in Python.
  defp ascii_letter("İ"), do: "i"

  defp ascii_letter(char) do
    Enum.find(
      [String.downcase(char), String.downcase(String.upcase(char))],
      &(&1 =~ ~r/\A[a-z]\z/)
    )
  end
end
