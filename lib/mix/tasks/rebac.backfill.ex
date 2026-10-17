defmodule Mix.Tasks.Rebac.Backfill do
  @moduledoc """
  Alias for `Mix.Tasks.AshAuthzed.Backfill` (`mix ash_authzed.backfill`).
  """
  use Mix.Task

  @shortdoc "Alias for mix ash_authzed.backfill"

  @impl true
  defdelegate run(args), to: Mix.Tasks.AshAuthzed.Backfill
end
