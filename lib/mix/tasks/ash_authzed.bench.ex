defmodule Mix.Tasks.AshAuthzed.Bench do
  @moduledoc """
  Runs real-database (non-sandbox) or in-memory benchmarks and adapter parity checks
  for AshAuthzed across Licet, Memory, and SpiceDB (HTTP).

  ## Usage

      mix ash_authzed.bench --count 200
      mix ash_authzed.bench --count 200 --compare-spicedb
      mix ash_authzed.bench --resource MyApp.Accounts.User --count 200
  """
  use Mix.Task

  import Ash.Query

  alias Ash.Resource.Info
  alias AshAuthzed.Adapters.Licet, as: LicetAdapter
  alias AshAuthzed.Adapters.Memory
  alias AshAuthzed.Adapters.SpiceDBHttp

  @shortdoc "Benchmarks AshAuthzed against configured adapters (Licet, Memory, SpiceDB)"

  @switches [
    count: :integer,
    compare_spicedb: :boolean,
    batch_size: :integer,
    resource: :string,
    adapter: :string
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    count = Keyword.get(opts, :count, 200)
    batch_size = Keyword.get(opts, :batch_size, 100)
    compare_spicedb? = Keyword.get(opts, :compare_spicedb, false)
    resource = resolve_resource(opts[:resource])
    adapters = resolve_adapters(opts[:adapter], compare_spicedb?, resource)

    Mix.shell().info(
      "\n=== AshAuthzed Benchmark (resource: #{inspect(resource)}, count: #{count}, batch_size: #{batch_size}) ===\n"
    )

    prev_adapter = Application.get_env(:ash_authzed, :adapter)

    try do
      results =
        for adapter <- adapters do
          Application.put_env(:ash_authzed, :adapter, adapter)
          run_suite_for_adapter(resource, adapter, count, batch_size)
        end

      print_summary_table(results)
    after
      if prev_adapter do
        Application.put_env(:ash_authzed, :adapter, prev_adapter)
      else
        Application.delete_env(:ash_authzed, :adapter)
      end
    end
  end

  defp resolve_resource(nil) do
    cond do
      Code.ensure_loaded?(AshAuthzed.Test.User) ->
        AshAuthzed.Test.User

      app = Mix.Project.config()[:app] ->
        case AshAuthzed.registered_resources(app) do
          [first | _] -> first
          [] -> ensure_bench_resource!()
        end

      true ->
        ensure_bench_resource!()
    end
  end

  defp resolve_resource(res_str) when is_binary(res_str) do
    Module.concat([res_str])
  end

  defp resolve_adapters(adapter_str, _compare_spicedb?, _resource) when is_binary(adapter_str) do
    [parse_adapter(adapter_str)]
  end

  defp resolve_adapters(nil, true, resource) do
    base = default_adapter_for(resource)
    Enum.uniq([base, SpiceDBHttp])
  end

  defp resolve_adapters(nil, false, resource) do
    [Application.get_env(:ash_authzed, :adapter, default_adapter_for(resource))]
  end

  defp default_adapter_for(resource) do
    case AshAuthzed.get_opt(resource, :adapter, :licet) do
      :memory -> Memory
      :spicedb_http -> SpiceDBHttp
      :licet -> LicetAdapter
      mod -> mod
    end
  end

  defp parse_adapter("memory"), do: Memory
  defp parse_adapter("licet"), do: LicetAdapter
  defp parse_adapter("spicedb_http"), do: SpiceDBHttp
  defp parse_adapter(mod_str), do: Module.concat([mod_str])

  defp run_suite_for_adapter(resource, adapter, count, batch_size) do
    maybe_start_memory_store(resource, adapter)
    run_id = System.unique_integer([:positive])
    Mix.shell().info("Running suite for #{inspect(adapter)}...")

    try do
      # 1. Measure Single Create (with commit + tuple write)
      {single_create_us, root} =
        :timer.tc(fn ->
          resource
          |> Ash.Changeset.for_create(
            :create,
            build_attrs(resource, "bench_root_#{run_id}", "Bench Root", :super_admin)
          )
          |> Ash.create!(authorize?: false)
        end)

      alice =
        resource
        |> Ash.Changeset.for_create(
          :create,
          build_attrs(resource, "bench_alice_#{run_id}", "Bench Alice", :admin)
        )
        |> Ash.create!(actor: root)

      # 2. Measure Bulk Create of `count` users
      default_role = default_member_role(resource)

      inputs =
        for i <- 1..count do
          build_attrs(resource, "bench_u_#{run_id}_#{i}", "Bench User #{i}", default_role)
        end

      {bulk_create_us, bulk_res} =
        :timer.tc(fn ->
          Ash.bulk_create!(inputs, resource, :create,
            actor: alice,
            batch_size: batch_size,
            return_records?: true,
            transaction: :batch
          )
        end)

      sample_user = hd(bulk_res.records)

      # 3. Measure Single Permission Check (`Ash.can?` -> `Adapter.check/4` or `lookup_resources/4`)
      {single_check_us, true} =
        :timer.tc(fn ->
          Ash.can?({sample_user, :update_profile, %{name: "Checked"}}, alice)
        end)

      # 4. Measure Collection Read with `lookup_resources` (`Ash.read!`)
      all_created_ids = Enum.map(bulk_res.records, & &1.id)

      {collection_read_us, visible_users} =
        :timer.tc(fn ->
          resource
          |> filter(id in ^all_created_ids)
          |> Ash.read!(actor: alice, page: false)
        end)

      assert_count!(length(visible_users), count, "Collection read count mismatch")

      # 5. Measure Bulk Promotion (`Ash.bulk_update!`)
      promote_ids = Enum.take(all_created_ids, min(50, count))

      {atomic_update_us, _} =
        :timer.tc(fn ->
          resource
          |> filter(id in ^promote_ids)
          |> Ash.bulk_update!(:change_role, %{role: :admin},
            actor: root,
            strategy: [:atomic_batches, :stream],
            batch_size: batch_size,
            transaction: :batch
          )
        end)

      %{
        adapter: inspect(adapter),
        single_create_ms: Float.round(single_create_us / 1_000, 2),
        bulk_create_total_ms: Float.round(bulk_create_us / 1_000, 2),
        bulk_create_per_row_ms: Float.round(bulk_create_us / 1_000 / count, 3),
        single_check_ms: Float.round(single_check_us / 1_000, 2),
        collection_read_ms: Float.round(collection_read_us / 1_000, 2),
        atomic_promote_50_ms: Float.round(atomic_update_us / 1_000, 2)
      }
    after
      # Clean up benchmark rows and tuples
      resource
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.filter(fn u ->
        String.contains?(to_string(u.id), "bench_") or
          String.contains?(to_string(Map.get(u, :email, "")), "bench_")
      end)
      |> Enum.map(& &1.id)
      |> case do
        [] ->
          :ok

        ids ->
          resource
          |> filter(id in ^ids)
          |> Ash.bulk_destroy!(:destroy, %{},
            authorize?: false,
            strategy: [:stream, :atomic_batches]
          )
      end
    end
  end

  defp maybe_start_memory_store(resource, adapter)
       when adapter in [:memory, Memory] do
    adapter_opts = AshAuthzed.get_opt(resource, :adapter_opts, [])
    store = Keyword.get(adapter_opts, :store, Memory)

    if is_nil(Process.whereis(store)) do
      {:ok, parsed} = Licet.Validate.parse(File.read!("priv/licet/user_permissions.yaml"))
      {:ok, _pid} = Memory.start_link(name: store, schema: parsed.schema)
    end
  end

  defp maybe_start_memory_store(_resource, _adapter), do: :ok

  defp default_member_role(resource) do
    case Info.attribute(resource, :role) do
      %{constraints: constraints} ->
        one_of = constraints[:one_of] || []
        if :member in one_of, do: :member, else: :user

      _ ->
        :user
    end
  end

  defp build_attrs(resource, id_base, name, role) do
    attrs = %{name: name, role: role}

    attrs =
      if Info.attribute(resource, :email) do
        Map.put(attrs, :email, "#{id_base}@example.com")
      else
        attrs
      end

    case Info.attribute(resource, :id) do
      %{writable?: true, type: Ash.Type.String} ->
        Map.put(attrs, :id, id_base)

      _ ->
        attrs
    end
  end

  defp ensure_bench_resource! do
    if is_nil(Application.get_env(:ash, :default_string_length_count)) do
      Application.put_env(:ash, :default_string_length_count, :codepoints)
    end

    prev_ignore = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Code.compile_file("test/support/accounts.ex")
    after
      Code.put_compiler_option(:ignore_module_conflict, prev_ignore)
    end

    AshAuthzed.Test.User
  end

  defp assert_count!(actual, expected, msg) do
    if actual != expected, do: Mix.raise("#{msg}: expected #{expected}, got #{actual}")
  end

  defp print_summary_table(results) do
    Mix.shell().info("\n--- Benchmark Results ---")

    header =
      String.pad_trailing("Adapter", 32) <>
        String.pad_trailing("1x Create", 12) <>
        String.pad_trailing("Bulk Create (per row)", 24) <>
        String.pad_trailing("1x Ash.can?", 14) <>
        String.pad_trailing("Read List", 12) <>
        "Atomic Bulk Update (50)"

    Mix.shell().info(header)
    Mix.shell().info(String.duplicate("-", String.length(header)))

    for r <- results do
      row =
        String.pad_trailing(r.adapter, 32) <>
          String.pad_trailing("#{r.single_create_ms} ms", 12) <>
          String.pad_trailing(
            "#{r.bulk_create_total_ms} ms (#{r.bulk_create_per_row_ms} ms/row)",
            24
          ) <>
          String.pad_trailing("#{r.single_check_ms} ms", 14) <>
          String.pad_trailing("#{r.collection_read_ms} ms", 12) <>
          "#{r.atomic_promote_50_ms} ms"

      Mix.shell().info(row)
    end

    Mix.shell().info("")
  end
end
