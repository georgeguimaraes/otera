defmodule Otera.Template do
  @moduledoc """
  A parsed template. `Otera.parse/2` makes it, and `Otera.render/3` renders it many times without parsing it again.

  `name` is the name of the template, `nil` for a template from a string without the `:name` option. `options` holds the options of `Otera.parse/2`, which also apply to each render. `scope` is the root scope from `Otera.Scope`, `blocks` holds the blocks of the template by name, and `extends?` is true when the template has an extends tag.
  """

  defstruct [:name, :source, :ast, :scope, blocks: %{}, extends?: false, options: []]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          source: String.t(),
          ast: list,
          scope: Otera.Scope.t(),
          blocks: %{String.t() => tuple},
          extends?: boolean,
          options: keyword
        }

  @doc """
  Loads the template `name` with the `:loader` of `opts` and parses it with `opts`. Raises `Otera.Error` with the kind `:template_not_found`, or `Otera.SyntaxError`.

  A template that the loader gives as an `Otera.Template` without a name gets the name `name`. With the `:cache` option, the template comes from that `Otera.Cache` while it is fresh.
  """
  @spec load(String.t(), keyword) :: t
  def load(name, opts) do
    loader =
      Keyword.get(opts, :loader) ||
        raise Otera.Error, kind: :type_error, message: "no loader for this environment specified"

    case Keyword.get(opts, :cache) do
      nil ->
        name |> load_source(loader, opts) |> elem(0)

      cache ->
        # The cache keeps templates without their options, which come from each call.
        key = {if(is_map(loader), do: :map, else: loader), name, parse_key(opts)}

        load = fn ->
          name
          |> load_source(loader, opts)
          |> then(fn {t, check} -> {%{t | options: []}, check} end)
        end

        template = Otera.Cache.fetch(cache, key, &fresh?(&1, loader, name), load)
        %{template | options: Keyword.put(opts, :name, name)}
    end
  end

  # Returns the template and the check that tells the cache if the template is still fresh.
  defp load_source(name, loader, opts) do
    case Otera.Loader.get_source(loader, name) do
      {:ok, %__MODULE__{name: nil} = template} -> {%{template | name: name}, nil}
      {:ok, %__MODULE__{} = template} -> {template, nil}
      {:ok, source, uptodate} -> {parse(source, name, opts), {:uptodate, uptodate}}
      {:ok, source} when is_map(loader) -> {parse(source, name, opts), {:source, source}}
      {:ok, source} -> {parse(source, name, opts), nil}
      :error -> raise Otera.Error, kind: :template_not_found, message: name
    end
  end

  defp parse(source, name, opts), do: parsed(Otera.parse(source, Keyword.put(opts, :name, name)))

  defp fresh?(nil, _loader, _name), do: true
  defp fresh?({:uptodate, uptodate}, _loader, _name), do: uptodate.() == true
  defp fresh?({:source, source}, loader, name), do: Map.fetch(loader, name) == {:ok, source}

  # The options that change the result of a parse.
  defp parse_key(opts) do
    names = fn key ->
      opts |> Keyword.get(key, %{}) |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    end

    {Keyword.get(opts, :trim_blocks, false), Keyword.get(opts, :lstrip_blocks, false),
     Keyword.get(opts, :keep_trailing_newline, false), names.(:filters), names.(:tests)}
  end

  defp parsed({:ok, template}), do: template
  defp parsed({:error, error}), do: raise(error)
end
