defmodule AshAuthzed.Adapters.Licet do
  @moduledoc """
  Adapter for evaluating permissions and storing relationship tuples using
  an embedded `Licet` instance backed by Postgres / Ecto.

  ## Options

  * `:instance` (required) - The atom name of the supervised `Licet` instance (e.g., `MyApp.Licet`).
  * `:consistency` - Snapshot consistency passed to `Licet.check/5` and `Licet.lookup_resources/5`. Defaults to `:full` so permission checks immediately observe committed writes without quantization lag (pass `:minimize_latency` to opt into quantized caching).
  * `:write_mode` - Whether `:create` operations should use `:touch` (idempotent) or `:create` (strict). Defaults to `:touch`.
  """

  @behaviour AshAuthzed.Adapter

  alias AshAuthzed.Error

  @impl true
  def check(resource, permission, subject, opts) do
    with {:ok, instance} <- fetch_instance(opts) do
      licet_opts =
        opts
        |> Keyword.take([:consistency])
        |> Keyword.put_new(:consistency, :full)

      case Licet.check(instance, resource, permission, subject, licet_opts) do
        {:ok, :allowed} -> {:ok, true}
        {:ok, :denied} -> {:ok, false}
        {:error, reason} -> {:error, Error.new(:licet_check_failed, reason)}
      end
    end
  end

  @impl true
  def lookup_resources(resource_type, permission, subject, opts) do
    with {:ok, instance} <- fetch_instance(opts) do
      licet_opts =
        opts
        |> Keyword.take([:consistency, :limit])
        |> Keyword.put_new(:consistency, :full)

      collect_all_pages(instance, resource_type, permission, subject, licet_opts, nil, [])
    end
  end

  @impl true
  def write_tuples([], _opts), do: {:ok, :noop}

  def write_tuples(operations, opts) do
    with {:ok, instance} <- fetch_instance(opts) do
      write_mode = Keyword.get(opts, :write_mode, :touch)

      normalized_ops =
        Enum.map(operations, fn
          {:create, tuple} when write_mode == :touch -> {:touch, tuple}
          {op, tuple} -> {op, tuple}
        end)

      licet_opts = Keyword.take(opts, [:preconditions, :metadata])

      case Licet.write(instance, normalized_ops, licet_opts) do
        {:ok, token} -> {:ok, token}
        {:error, reason} -> {:error, Error.new(:licet_write_failed, reason)}
      end
    end
  end

  @impl true
  def apply_schema(schema_text, opts) do
    with {:ok, instance} <- fetch_instance(opts) do
      licet_opts = Keyword.take(opts, [:metadata])

      case Licet.write_schema(instance, schema_text, licet_opts) do
        {:ok, token} -> {:ok, token}
        :ok -> :ok
        {:error, reason} -> {:error, Error.new(:licet_write_schema_failed, reason)}
      end
    end
  end

  defp collect_all_pages(instance, resource_type, permission, subject, opts, cursor, acc) do
    page_opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

    case Licet.lookup_resources(instance, resource_type, permission, subject, page_opts) do
      {:ok, ids, nil} ->
        {:ok, [ids | acc] |> Enum.reverse() |> List.flatten()}

      {:ok, ids, next_cursor} ->
        collect_all_pages(
          instance,
          resource_type,
          permission,
          subject,
          opts,
          next_cursor,
          [ids | acc]
        )

      {:error, reason} ->
        {:error, Error.new(:licet_lookup_failed, reason)}
    end
  end

  defp fetch_instance(opts) do
    case Keyword.fetch(opts, :instance) do
      {:ok, instance} when is_atom(instance) and not is_nil(instance) ->
        {:ok, instance}

      _ ->
        {:error,
         Error.new(
           :missing_instance,
           "AshAuthzed.Adapters.Licet requires an `:instance` option (e.g. `instance: MyApp.Licet`)"
         )}
    end
  end
end
