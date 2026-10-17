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
    all: :boolean,
    batch_size: :integer,
    resource: :string,
    adapter: :string
  ]

  defmodule BenchRepo do
    @moduledoc false
    use Ecto.Repo,
      otp_app: :ash_authzed,
      adapter: Ecto.Adapters.Postgres
  end

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    count = Keyword.get(opts, :count, 200)
    batch_size = Keyword.get(opts, :batch_size, 100)
    compare_spicedb? = Keyword.get(opts, :compare_spicedb, false)
    all? = Keyword.get(opts, :all, false)
    resource = resolve_resource(opts[:resource])
    adapters = resolve_adapters(opts[:adapter], compare_spicedb?, all?, resource)

    Mix.shell().info(
      "\n=== AshAuthzed Benchmark (resource: #{inspect(resource)}, count: #{count}, batch_size: #{batch_size}) ===\n"
    )

    prev_adapter = Application.get_env(:ash_authzed, :adapter)
    prev_adapter_opts = Application.get_env(:ash_authzed, :adapter_opts)

    try do
      results =
        for adapter <- adapters do
          Application.put_env(:ash_authzed, :adapter, adapter)
          run_suite_for_adapter(resource, adapter, count, batch_size)
        end

      print_summary_table(results)
    after
      restore_env(:adapter, prev_adapter)
      restore_env(:adapter_opts, prev_adapter_opts)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:ash_authzed, key)
  defp restore_env(key, val), do: Application.put_env(:ash_authzed, key, val)

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

  defp resolve_adapters("all", _compare_spicedb?, _all?, _resource) do
    [Memory, LicetAdapter, SpiceDBHttp, :spicedb_postgres]
  end

  defp resolve_adapters(adapter_str, _compare_spicedb?, _all?, _resource)
       when is_binary(adapter_str) do
    adapter_str
    |> String.split(",", trim: true)
    |> Enum.map(&parse_adapter/1)
  end

  defp resolve_adapters(nil, _compare_spicedb?, true, _resource) do
    [Memory, LicetAdapter, SpiceDBHttp, :spicedb_postgres]
  end

  defp resolve_adapters(nil, true, false, resource) do
    base = default_adapter_for(resource)
    Enum.uniq([base, SpiceDBHttp])
  end

  defp resolve_adapters(nil, false, false, resource) do
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
  defp parse_adapter("spicedb"), do: SpiceDBHttp
  defp parse_adapter("spicedb_postgres"), do: :spicedb_postgres
  defp parse_adapter(mod_str), do: Module.concat([mod_str])

  defp run_suite_for_adapter(resource, target, count, batch_size) do
    {adapter_mod, adapter_label, cleanup_fn} = setup_adapter_backend(resource, target)
    Application.put_env(:ash_authzed, :adapter, adapter_mod)
    run_id = System.unique_integer([:positive])
    Mix.shell().info("Running suite for #{adapter_label}...")

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
        adapter: adapter_label,
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

      cleanup_fn.()
    end
  end

  defp setup_adapter_backend(resource, adapter) when adapter in [:memory, Memory] do
    adapter_opts = AshAuthzed.get_opt(resource, :adapter_opts, [])
    store = Keyword.get(adapter_opts, :store, Memory)

    if is_nil(Process.whereis(store)) do
      {:ok, parsed} = Licet.Validate.parse(File.read!("priv/licet/user_permissions.yaml"))
      {:ok, _pid} = Memory.start_link(name: store, schema: parsed.schema)
    end

    Application.put_env(:ash_authzed, :adapter_opts, store: store)
    {Memory, "AshAuthzed.Adapters.Memory", fn -> :ok end}
  end

  defp setup_adapter_backend(resource, adapter) when adapter in [:licet, LicetAdapter] do
    adapter_opts = AshAuthzed.get_opt(resource, :adapter_opts, [])

    cleanup =
      if Keyword.has_key?(adapter_opts, :instance) and
           not is_nil(Process.whereis(adapter_opts[:instance])) do
        fn -> :ok end
      else
        start_ephemeral_licet!()
      end

    {LicetAdapter, "AshAuthzed.Adapters.Licet (PG)", cleanup}
  end

  defp setup_adapter_backend(resource, adapter) when adapter in [:spicedb_http, SpiceDBHttp] do
    adapter_opts = AshAuthzed.get_opt(resource, :adapter_opts, [])
    url = Keyword.get(adapter_opts, :url, System.get_env("SPICEDB_URL", "http://127.0.0.1:18443"))
    token = Keyword.get(adapter_opts, :token, System.get_env("SPICEDB_TOKEN", "bench_secret"))

    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, yaml_map} = YamlElixir.read_from_file("priv/licet/user_permissions.yaml")
    schema_text = Map.fetch!(yaml_map, "schema")

    {started_os_pid, active_url} =
      case push_spicedb_schema(url, token, schema_text) do
        :ok ->
          {nil, url}

        {:error, _} ->
          start_ephemeral_spicedb!(token, schema_text, [])
      end

    Application.put_env(:ash_authzed, :adapter_opts,
      url: active_url,
      token: token,
      consistency: :fully_consistent
    )

    cleanup = fn ->
      if started_os_pid do
        System.cmd("kill", ["-9", to_string(started_os_pid)], stderr_to_stdout: true)
      end
    end

    {SpiceDBHttp, "AshAuthzed.Adapters.SpiceDBHttp (Mem)", cleanup}
  end

  defp setup_adapter_backend(_resource, :spicedb_postgres) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:req)

    pg_url = System.get_env("POSTGRES_URL", "ecto://postgres:postgres@localhost/postgres")
    repo_pid = ensure_bench_repo_started!(pg_url)
    db_name = "spicedb_bench_#{System.unique_integer([:positive])}"
    BenchRepo.query!("CREATE DATABASE #{db_name}", [])

    conn_uri =
      pg_url
      |> String.replace_prefix("ecto://", "postgres://")
      |> String.replace(~r"/[^/]+$", "/#{db_name}?sslmode=disable")

    spicedb_bin = find_spicedb_executable!()

    {_, 0} =
      System.cmd(
        spicedb_bin,
        [
          "datastore",
          "migrate",
          "head",
          "--datastore-engine=postgres",
          "--datastore-conn-uri=#{conn_uri}",
          "--skip-release-check"
        ],
        stderr_to_stdout: true
      )

    {:ok, yaml_map} = YamlElixir.read_from_file("priv/licet/user_permissions.yaml")
    schema_text = Map.fetch!(yaml_map, "schema")
    token = "bench_pg_secret"

    {os_pid, active_url} =
      start_ephemeral_spicedb!(token, schema_text, [
        "--datastore-engine=postgres",
        "--datastore-conn-uri=#{conn_uri}"
      ])

    Application.put_env(:ash_authzed, :adapter_opts,
      url: active_url,
      token: token,
      consistency: :fully_consistent
    )

    cleanup = fn ->
      System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
      Process.sleep(100)
      BenchRepo.query!("DROP DATABASE IF EXISTS #{db_name} WITH (FORCE)", [])
      stop_if_alive(repo_pid)
    end

    {SpiceDBHttp, "AshAuthzed.Adapters.SpiceDBHttp (PG)", cleanup}
  end

  defp setup_adapter_backend(_resource, adapter) do
    {adapter, inspect(adapter), fn -> :ok end}
  end

  defp start_ephemeral_licet! do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    pg_url = System.get_env("POSTGRES_URL", "ecto://postgres:postgres@localhost/postgres")
    repo_pid = ensure_bench_repo_started!(pg_url)

    prefix = "licet_bench_#{System.unique_integer([:positive])}"
    Licet.Testing.migrate!(BenchRepo, prefix)

    {:ok, parsed} = Licet.Validate.parse(File.read!("priv/licet/user_permissions.yaml"))
    instance = :"licet_bench_inst_#{System.unique_integer([:positive])}"

    {:ok, licet_pid} =
      Licet.start_link(
        name: instance,
        repo: BenchRepo,
        prefix: prefix,
        schema: {:string, parsed.schema.source}
      )

    Application.put_env(:ash_authzed, :adapter_opts, instance: instance)

    fn ->
      stop_if_alive(licet_pid)
      BenchRepo.query!("DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
      stop_if_alive(repo_pid)
    end
  end

  defp ensure_bench_repo_started!(pg_url) do
    case BenchRepo.start_link(url: pg_url, pool_size: 10, log: false) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  end

  defp push_spicedb_schema(url, token, schema_text) do
    case Req.post(
           url: String.trim_trailing(url, "/") <> "/v1/schema/write",
           headers: [{"authorization", "Bearer #{token}"}],
           json: %{schema: schema_text},
           retry: false
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end

  defp find_spicedb_executable! do
    System.find_executable("spicedb") ||
      Mix.raise("Could not connect to SpiceDB and `spicedb` executable was not found in PATH.")
  end

  defp start_ephemeral_spicedb!(token, schema_text, extra_args) do
    spicedb_bin = find_spicedb_executable!()

    http_port = Enum.random(28_000..29_000)
    grpc_port = http_port + 1
    url = "http://127.0.0.1:#{http_port}"

    base_args = [
      "serve",
      "--grpc-preshared-key",
      token,
      "--http-enabled",
      "--http-addr",
      "127.0.0.1:#{http_port}",
      "--grpc-addr",
      "127.0.0.1:#{grpc_port}",
      "--metrics-enabled=false",
      "--telemetry-endpoint=",
      "--skip-release-check"
    ]

    port =
      Port.open({:spawn_executable, spicedb_bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: base_args ++ extra_args
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    wait_for_spicedb!(url, token, schema_text, 40)
    {os_pid, url}
  end

  defp wait_for_spicedb!(_url, _token, _schema_text, 0) do
    Mix.raise("Timed out waiting for local `spicedb serve` HTTP server to start.")
  end

  defp wait_for_spicedb!(url, token, schema_text, attempts) do
    case push_spicedb_schema(url, token, schema_text) do
      :ok ->
        :ok

      {:error, _} ->
        Process.sleep(100)
        wait_for_spicedb!(url, token, schema_text, attempts - 1)
    end
  end

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
      String.pad_trailing("Adapter", 39) <>
        String.pad_trailing("1x Create", 12) <>
        String.pad_trailing("Bulk Create (per row)", 28) <>
        String.pad_trailing("1x Ash.can?", 14) <>
        String.pad_trailing("Read List", 12) <>
        "Atomic Bulk Update (50)"

    Mix.shell().info(header)
    Mix.shell().info(String.duplicate("-", String.length(header)))

    for r <- results do
      row =
        String.pad_trailing(r.adapter, 39) <>
          String.pad_trailing("#{r.single_create_ms} ms", 12) <>
          String.pad_trailing(
            "#{r.bulk_create_total_ms} ms (#{r.bulk_create_per_row_ms} ms/row)",
            28
          ) <>
          String.pad_trailing("#{r.single_check_ms} ms", 14) <>
          String.pad_trailing("#{r.collection_read_ms} ms", 12) <>
          "#{r.atomic_promote_50_ms} ms"

      Mix.shell().info(row)
    end

    Mix.shell().info("")
  end
end
