defmodule Otera.Namespace do
  @moduledoc """
  A `namespace()` object of Jinja2, which a template can change.

  `{% set ns.count = ns.count + 1 %}` changes the namespace everywhere it is referenced, also from inside a loop or a macro. The attributes live in `Otera.State`.
  """

  alias Otera.{Dict, State, Undefined}

  defstruct [:ref]

  @type t :: %__MODULE__{ref: reference}

  @doc """
  Makes a namespace with the attributes of `dict`.
  """
  @spec new(Dict.t()) :: t
  def new(%Dict{} = attributes) do
    namespace = %__MODULE__{ref: make_ref()}
    State.put(namespace.ref, attributes)
    namespace
  end

  @doc """
  Returns the attributes of `namespace` as a dict.
  """
  @spec attributes(t) :: Dict.t()
  def attributes(%__MODULE__{ref: ref}), do: State.get(ref)

  @doc """
  Returns `{:ok, value}` for the attribute `name`, or `:error`.
  """
  @spec fetch(t, String.t()) :: {:ok, term} | :error
  def fetch(namespace, name), do: Dict.fetch(attributes(namespace), name)

  @doc """
  Returns the attribute `name`, or an undefined value.
  """
  @spec get(t, String.t()) :: term
  def get(namespace, name) do
    case fetch(namespace, name) do
      {:ok, value} -> value
      :error -> %Undefined{obj: namespace, name: name}
    end
  end

  @doc """
  Sets the attribute `name` to `value`.
  """
  @spec put(t, String.t(), term) :: :ok
  def put(%__MODULE__{ref: ref} = namespace, name, value),
    do: State.put(ref, Dict.put(attributes(namespace), name, value))
end
