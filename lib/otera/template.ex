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

  A template that the loader gives as an `Otera.Template` without a name gets the name `name`.
  """
  @spec load(String.t(), keyword) :: t
  def load(name, opts) do
    loader =
      Keyword.get(opts, :loader) ||
        raise Otera.Error, kind: :type_error, message: "no loader for this environment specified"

    case Otera.Loader.get_source(loader, name) do
      {:ok, %__MODULE__{name: nil} = template} -> %{template | name: name}
      {:ok, %__MODULE__{} = template} -> template
      {:ok, source} -> parsed(Otera.parse(source, Keyword.put(opts, :name, name)))
      :error -> raise Otera.Error, kind: :template_not_found, message: name
    end
  end

  defp parsed({:ok, template}), do: template
  defp parsed({:error, error}), do: raise(error)
end
