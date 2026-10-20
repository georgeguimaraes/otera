defmodule Otera.Lipsum do
  @moduledoc """
  The `lipsum(n=5, html=True, min=20, max=100)` function of Jinja2: `n` paragraphs of random lorem ipsum, with the algorithm and the words of Jinja2. The text is random, as in Python.
  """

  @words ~w(a ac accumsan ad adipiscing aenean aliquam aliquet amet ante aptent arcu at auctor augue bibendum blandit class commodo condimentum congue consectetuer consequat conubia convallis cras cubilia cum curabitur curae cursus dapibus diam dictum dictumst dignissim dis dolor donec dui duis egestas eget eleifend elementum elit enim erat eros est et etiam eu euismod facilisi facilisis fames faucibus felis fermentum feugiat fringilla fusce gravida habitant habitasse hac hendrerit hymenaeos iaculis id imperdiet in inceptos integer interdum ipsum justo lacinia lacus laoreet lectus leo libero ligula litora lobortis lorem luctus maecenas magna magnis malesuada massa mattis mauris metus mi molestie mollis montes morbi mus nam nascetur natoque nec neque netus nibh nisi nisl non nonummy nostra nulla nullam nunc odio orci ornare parturient pede pellentesque penatibus per pharetra phasellus placerat platea porta porttitor posuere potenti praesent pretium primis proin pulvinar purus quam quis quisque rhoncus ridiculus risus rutrum sagittis sapien scelerisque sed sem semper senectus sit sociis sociosqu sodales sollicitudin suscipit suspendisse taciti tellus tempor tempus tincidunt torquent tortor tristique turpis ullamcorper ultrices ultricies urna ut varius vehicula vel velit venenatis vestibulum vitae vivamus viverra volutpat vulputate)

  @doc """
  Returns `count` paragraphs of `min` to `max` words, as HTML paragraphs when `html` is true.
  """
  @spec generate(integer, boolean, integer, integer) :: String.t()
  def generate(count, html, min, max) do
    paragraphs = for _ <- 1..count//1, do: paragraph(min, max)

    if html,
      do: Enum.map_join(paragraphs, "\n", &"<p>#{Otera.HTML.escape(&1)}</p>"),
      else: Enum.join(paragraphs, "\n\n")
  end

  defp paragraph(min, max) do
    {words, _state} =
      Enum.map_reduce(0..(random(min, max) - 1)//1, {true, 0, 0, nil}, &word/2)

    text = Enum.join(words, " ")

    cond do
      String.ends_with?(text, ",") -> String.slice(text, 0..-2//1) <> "."
      String.ends_with?(text, ".") -> text
      true -> text <> "."
    end
  end

  defp word(index, {capitalize, last_comma, last_fullstop, last}) do
    word = Enum.random(@words -- [last])
    text = if capitalize, do: String.capitalize(word), else: word

    {text, last_comma, last_fullstop} =
      if index - random(3, 8) > last_comma,
        do: {text <> ",", index, last_fullstop + 2},
        else: {text, last_comma, last_fullstop}

    if index - random(10, 20) > last_fullstop,
      do: {text <> ".", {true, index, index, word}},
      else: {text, {false, last_comma, last_fullstop, word}}
  end

  # Python random.randrange(min, max) excludes max.
  defp random(min, max), do: min + :rand.uniform(max - min) - 1
end
