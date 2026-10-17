defmodule AshAuthzed.Error do
  @moduledoc """
  Exception raised or returned when an `AshAuthzed` operation fails.
  """

  defexception [:reason, :details]

  @type t :: %__MODULE__{
          reason: atom(),
          details: term()
        }

  @spec new(atom(), term()) :: t()
  def new(reason, details \\ nil) when is_atom(reason) do
    %__MODULE__{reason: reason, details: details}
  end

  @impl Exception
  def message(%__MODULE__{reason: reason, details: nil}) do
    "AshAuthzed error: #{inspect(reason)}"
  end

  def message(%__MODULE__{reason: reason, details: details}) when is_binary(details) do
    "AshAuthzed error (#{reason}): #{details}"
  end

  def message(%__MODULE__{reason: reason, details: details}) do
    "AshAuthzed error (#{reason}): #{inspect(details)}"
  end
end
