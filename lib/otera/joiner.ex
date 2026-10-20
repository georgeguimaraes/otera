defmodule Otera.Joiner do
  @moduledoc """
  The `joiner(sep=", ")` object of Jinja2. A call gives an empty string the first time and `sep` after that. Whether it was called lives in `Otera.State`.
  """

  alias Otera.{State, Undefined}

  defstruct [:ref, :sep]

  @doc """
  Makes a joiner with the separator `sep`.
  """
  @spec new(term) :: %__MODULE__{}
  def new(sep), do: %__MODULE__{ref: make_ref(), sep: sep}

  @doc """
  Calls the joiner.
  """
  @spec call(%__MODULE__{}) :: term
  def call(joiner) do
    if State.get(joiner.ref, false) do
      joiner.sep
    else
      State.put(joiner.ref, true)
      ""
    end
  end

  @doc """
  Returns the attribute `name` of `joiner`.
  """
  @spec get(%__MODULE__{}, String.t()) :: term
  def get(joiner, "sep"), do: joiner.sep
  def get(joiner, "used"), do: State.get(joiner.ref, false)
  def get(joiner, name), do: %Undefined{obj: joiner, name: name}
end
