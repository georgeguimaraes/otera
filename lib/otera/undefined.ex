defmodule Otera.Undefined do
  @moduledoc """
  The value of a missing variable, attribute or item, like the default `Undefined` of Jinja2.

  An undefined value prints as an empty string, is false, has a length of 0 and iterates as an empty sequence. Other operations on it, such as arithmetic, calls or attribute lookup, raise an `Otera.Error` with the message that Jinja2 gives, for example `'user' is undefined`.

  A custom filter, test or function can receive an undefined value as an argument.
  """

  alias Otera.Value

  defstruct hint: nil, obj: :missing, name: nil, kind: :undefined_error

  @type t :: %__MODULE__{hint: String.t() | nil, obj: term, name: term, kind: atom}

  @doc """
  Returns the message of the error that an operation on `undefined` raises.
  """
  @spec message(t) :: String.t()
  def message(%__MODULE__{hint: hint}) when is_binary(hint), do: hint
  def message(%__MODULE__{obj: :missing, name: name}), do: "#{Value.repr(name)} is undefined"

  def message(%__MODULE__{obj: obj, name: name}) when is_binary(name),
    do: "#{Value.repr(Value.object_type_repr(obj))} has no attribute #{Value.repr(name)}"

  def message(%__MODULE__{obj: obj, name: name}),
    do: "#{Value.object_type_repr(obj)} has no element #{Value.repr(name)}"

  @doc """
  Raises the error of an operation on `undefined`.
  """
  @spec fail(t) :: no_return
  def fail(%__MODULE__{kind: kind} = undefined),
    do: raise(Otera.Error, kind: kind, message: message(undefined))
end
