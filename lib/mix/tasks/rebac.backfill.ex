defmodule Mix.Tasks.Rebac.Backfill do
  @moduledoc """
  Streams existing Ash resources from the database and synchronizes their
  Zanzibar / ReBAC relationship tuples into Licet or SpiceDB.

  ## Examples

      # Backfill all resources using AshAuthzed in the current project
      mix rebac.backfill

      # Backfill a specific resource with a custom batch size
      mix rebac.backfill --resource MyApp.Accounts.User --batch-size 250

      # Preview tuple counts without writing to Licet / SpiceDB
      mix rebac.backfill --dry-run

      # Skip deleting non-matching external_role enum values (append-only mode)
      mix rebac.backfill --no-reconcile
  """
  use Mix.Task

  @shortdoc "Backfills AshAuthzed relationship tuples for existing database records"

  @switches [
    app: :string,
    domain: :keep,
    resource: :keep,
    batch_size: :integer,
    reconcile: :boolean,
    dry_run: :boolean,
    tenant: :string
  ]

  @aliases [
    r: :resource,
    d: :domain,
    b: :batch_size,
    n: :dry_run,
    t: :tenant
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    batch_size = Keyword.get(opts, :batch_size, 500)
    reconcile? = Keyword.get(opts, :reconcile, true)
    dry_run? = Keyword.get(opts, :dry_run, false)
    tenant = Keyword.get(opts, :tenant)

    resources = resolve_target_resources(opts)

    if resources == [] do
      Mix.shell().info("No Ash resources with the AshAuthzed extension were found.")
    else
      run_backfill_for_resources(resources, batch_size, reconcile?, dry_run?, tenant)
    end
  end

  defp run_backfill_for_resources(resources, batch_size, reconcile?, dry_run?, tenant) do
    mode_label = if dry_run?, do: " [DRY RUN]", else: ""

    Mix.shell().info(
      "Starting AshAuthzed backfill#{mode_label} for #{length(resources)} resource(s)..."
    )

    backfill_opts = [
      batch_size: batch_size,
      reconcile?: reconcile?,
      dry_run?: dry_run?,
      tenant: tenant
    ]

    Enum.each(resources, &backfill_single_resource(&1, backfill_opts, batch_size, reconcile?))

    Mix.shell().info("Backfill complete#{mode_label}.")
  end

  defp backfill_single_resource(resource, backfill_opts, batch_size, reconcile?) do
    Mix.shell().info(
      "  -> Streaming #{inspect(resource)} (batch_size: #{batch_size}, reconcile?: #{reconcile?})..."
    )

    case AshAuthzed.backfill(resource, backfill_opts) do
      {:ok, stats} ->
        Mix.shell().info(
          "     Completed #{inspect(resource)}: #{stats.records} record(s), " <>
            "#{stats.operations} tuple op(s) across #{stats.batches} batch(es)."
        )

      {:error, reason} ->
        Mix.raise("Failed backfilling #{inspect(resource)}: #{inspect(reason)}")
    end
  end

  defp resolve_target_resources(opts) do
    explicit_resources =
      opts
      |> Keyword.get_values(:resource)
      |> Enum.map(&Module.concat([&1]))

    explicit_domains =
      opts
      |> Keyword.get_values(:domain)
      |> Enum.map(&Module.concat([&1]))

    cond do
      explicit_resources != [] ->
        explicit_resources

      explicit_domains != [] ->
        AshAuthzed.registered_resources(explicit_domains)

      app_str = opts[:app] ->
        AshAuthzed.registered_resources(String.to_existing_atom(app_str))

      app = Mix.Project.config()[:app] ->
        AshAuthzed.registered_resources(app)

      true ->
        []
    end
  end
end
