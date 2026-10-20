defmodule Otera.Loader do
  @moduledoc """
  Loads the templates that `{% extends %}`, `{% include %}` and `{% import %}` name, like the loaders of Jinja2.

  The `:loader` option of `Otera.parse/2`, `Otera.load/2` and `Otera.render/3` is one of these:

    * A map from names to sources, like the `DictLoader` of Jinja2:

          Otera.render(~s({% include "header.html" %}), %{}, loader: %{"header.html" => "<h1>Hi</h1>"})
          #=> {:ok, "<h1>Hi</h1>"}

    * A function that gets a name and returns `{:ok, source}`, or `:error` when there is no template with that name, like the `FunctionLoader` of Jinja2. It can also return `{:ok, source, uptodate}`, where `uptodate` is a function without arguments that returns false when the template changed, for `Otera.Cache`.

    * `file_system/1`, which reads the templates from directories, like the `FileSystemLoader` of Jinja2.

  The values of a map and the results of a function can also be templates that `Otera.parse/2` made. During a render, Otera loads and parses each template once. To keep the parsed templates for many renders, give an `Otera.Cache` with the `:cache` option.
  """

  @type t :: %{String.t() => String.t() | Otera.Template.t()} | (String.t() -> result)

  @type result ::
          {:ok, String.t() | Otera.Template.t()} | {:ok, String.t(), (-> boolean)} | :error

  @doc """
  Returns a loader that reads the template `name` from the file `name` in `root`, a directory or a list of directories that it tries in order.

  The loader gives an `uptodate` function with each source, which returns false when the modification time or the size of the file changed, for `Otera.Cache`.

  The parts of a name are separated by `/`. As in Jinja2, a name with a `..` part is not found, and Otera also refuses a backslash and a null byte, so a template cannot be outside the directories. An empty part and a `.` part do nothing, so `/a.html` is the file `a.html` in a directory. The files are UTF-8.
  """
  @spec file_system(Path.t() | [Path.t()]) :: (String.t() -> result)
  def file_system(root) do
    roots = List.wrap(root)

    fn name ->
      with {:ok, pieces} <- split_template_path(name),
           do: Enum.find_value(roots, :error, &read(Path.join([&1 | pieces])))
    end
  end

  defp read(path) do
    with {:ok, stat} <- stat(path), {:ok, source} <- File.read(path) do
      {:ok, source, fn -> stat(path) == {:ok, stat} end}
    else
      _ -> nil
    end
  end

  defp stat(path) do
    with {:ok, %File.Stat{mtime: mtime, size: size}} <- File.stat(path), do: {:ok, {mtime, size}}
  end

  # split_template_path of Jinja2.
  defp split_template_path(name) do
    pieces = String.split(name, "/")

    if Enum.any?(pieces, &(&1 == ".." or String.contains?(&1, ["\\", <<0>>]))),
      do: :error,
      else: {:ok, Enum.reject(pieces, &(&1 in ["", "."]))}
  end

  @doc """
  Returns the template `name` from `loader`: `{:ok, source_or_template}`, `{:ok, source, uptodate}`, or `:error`.
  """
  @spec get_source(t, String.t()) :: result
  def get_source(loader, name) when is_map(loader), do: Map.fetch(loader, name)
  def get_source(loader, name) when is_function(loader, 1), do: loader.(name)
end
