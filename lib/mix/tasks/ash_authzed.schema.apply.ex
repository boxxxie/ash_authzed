defmodule Mix.Tasks.AshAuthzed.Schema.Apply do
  @moduledoc """
  Applies the `.zed` or YAML Zanzibar schema file to the active ReBAC adapter (`Licet`, `SpiceDB`, or `Memory`).

  ## Examples

      # Applies the default schema to the configured adapter
      mix ash_authzed.schema.apply

      # Specifies an explicit schema file path
      mix ash_authzed.schema.apply --schema priv/authzed/schema.zed

      # Target an explicit adapter (licet, spicedb_http, memory)
      mix ash_authzed.schema.apply --adapter spicedb_http
  """
  use Mix.Task

  @shortdoc "Applies the Zanzibar .zed schema to the configured ReBAC backend"

  @switches [
    schema: :string,
    adapter: :string
  ]

  @aliases [
    s: :schema,
    a: :adapter
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    schema_path = resolve_schema_path(opts)
    adapter_opt = resolve_adapter_opts(Keyword.get(opts, :adapter))

    Mix.shell().info("Applying schema from #{schema_path}...")
    handle_apply_result(AshAuthzed.apply_schema(schema_path, adapter_opt))
  end

  defp resolve_schema_path(opts) do
    path =
      Keyword.get(opts, :schema) ||
        Application.get_env(:ash_authzed, :schema_path, "priv/licet/user_permissions.yaml")

    if File.exists?(path) do
      path
    else
      Mix.raise("Schema file not found at: #{path}")
    end
  end

  defp resolve_adapter_opts(nil), do: []
  defp resolve_adapter_opts("licet"), do: [adapter: :licet]
  defp resolve_adapter_opts("spicedb"), do: [adapter: :spicedb_http]
  defp resolve_adapter_opts("spicedb_http"), do: [adapter: :spicedb_http]
  defp resolve_adapter_opts("memory"), do: [adapter: :memory]

  defp resolve_adapter_opts(other) do
    Mix.raise("Unknown adapter #{inspect(other)}. Expected licet, spicedb_http, or memory")
  end

  defp handle_apply_result(:ok) do
    Mix.shell().info("Schema successfully applied!")
  end

  defp handle_apply_result({:ok, token}) do
    Mix.shell().info("Schema successfully applied! Token: #{inspect(token)}")
  end

  defp handle_apply_result({:error, reason}) do
    Mix.raise("Failed to apply schema: #{inspect(reason)}")
  end
end
