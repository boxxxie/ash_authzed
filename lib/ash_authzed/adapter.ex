defmodule AshAuthzed.Adapter do
  @moduledoc """
  Behaviour and unified dispatcher for ReBAC backends (`Licet`, `SpiceDB` HTTP, or `Memory`).
  """

  alias AshAuthzed.Error

  @type operation :: {:create | :touch | :delete, String.t()}

  @callback check(
              resource :: String.t(),
              permission :: String.t(),
              subject :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, boolean()} | {:error, Exception.t()}

  @callback lookup_resources(
              resource_type :: String.t(),
              permission :: String.t(),
              subject :: String.t(),
              opts :: keyword()
            ) :: {:ok, [String.t()]} | {:error, Exception.t()}

  @callback write_tuples(operations :: [operation()], opts :: keyword()) ::
              {:ok, term()} | {:error, Exception.t()}

  @doc """
  Checks whether `subject` has `permission` on `resource`.
  Returns `true` if allowed, `false` otherwise.
  """
  @spec check?(String.t(), String.t() | atom(), String.t(), keyword()) :: boolean()
  def check?(resource, permission, subject, opts \\ []) do
    case check(resource, permission, subject, opts) do
      {:ok, allowed?} -> allowed?
      {:error, _} -> false
    end
  end

  @doc """
  Checks whether `subject` has `permission` on `resource`, returning `{:ok, boolean()}` or `{:error, Exception.t()}`.
  """
  @spec check(String.t(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, Exception.t()}
  def check(resource, permission, subject, opts \\ []) do
    {adapter_mod, adapter_opts} = resolve_adapter(opts)
    perm_str = to_string(permission)
    meta = %{adapter: adapter_mod, resource: resource, permission: perm_str, subject: subject}

    :telemetry.span([:ash_authzed, :check], meta, fn ->
      result = adapter_mod.check(resource, perm_str, subject, adapter_opts)
      {result, Map.put(meta, :status, status_from_result(result))}
    end)
  end

  @doc """
  Looks up all resource IDs of `resource_type` on which `subject` has `permission`.
  """
  @spec lookup_resources(String.t(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, Exception.t()}
  def lookup_resources(resource_type, permission, subject, opts \\ []) do
    {adapter_mod, adapter_opts} = resolve_adapter(opts)
    perm_str = to_string(permission)

    meta = %{
      adapter: adapter_mod,
      resource_type: resource_type,
      permission: perm_str,
      subject: subject
    }

    :telemetry.span([:ash_authzed, :lookup_resources], meta, fn ->
      result = adapter_mod.lookup_resources(resource_type, perm_str, subject, adapter_opts)
      {result, Map.put(meta, :status, status_from_result(result))}
    end)
  end

  @doc """
  Looks up all resource IDs of `resource_type` on which `subject` has `permission`, raising on error.
  """
  @spec lookup_resources!(String.t(), String.t() | atom(), String.t(), keyword()) :: [String.t()]
  def lookup_resources!(resource_type, permission, subject, opts \\ []) do
    case lookup_resources(resource_type, permission, subject, opts) do
      {:ok, ids} -> ids
      {:error, error} -> raise error
    end
  end

  @doc """
  Applies a list of relationship tuple operations (`{:create | :touch | :delete, tuple_string}`).
  """
  @spec write_tuples([operation()], keyword()) :: {:ok, term()} | {:error, Exception.t()}
  def write_tuples(operations, opts \\ [])
  def write_tuples([], _opts), do: {:ok, :noop}

  def write_tuples(operations, opts) when is_list(operations) do
    {adapter_mod, adapter_opts} = resolve_adapter(opts)
    count = length(operations)
    meta = %{adapter: adapter_mod, operation_count: count, operations: operations}

    :telemetry.execute(
      [:ash_authzed, :adapter, :write_tuples],
      %{tuple_count: count},
      %{adapter: adapter_mod, operations: operations}
    )

    :telemetry.span([:ash_authzed, :write_tuples], meta, fn ->
      result = adapter_mod.write_tuples(operations, adapter_opts)
      {result, Map.put(meta, :status, status_from_result(result))}
    end)
  end

  defp status_from_result(:ok), do: :ok

  defp status_from_result(result) when is_tuple(result) and tuple_size(result) > 0,
    do: elem(result, 0)

  defp status_from_result(_), do: :unknown

  @doc false
  @spec resolve_adapter(keyword()) :: {module(), keyword()}
  def resolve_adapter(opts) do
    default_adapter = Application.get_env(:ash_authzed, :adapter, AshAuthzed.Adapters.Licet)
    adapter = Keyword.get(opts, :adapter, default_adapter)
    default_adapter_opts = Application.get_env(:ash_authzed, :adapter_opts, [])
    adapter_opts = Keyword.merge(default_adapter_opts, Keyword.get(opts, :adapter_opts, []))
    merged_opts = Keyword.merge(adapter_opts, Keyword.drop(opts, [:adapter, :adapter_opts]))

    case adapter do
      :licet -> {AshAuthzed.Adapters.Licet, merged_opts}
      :spicedb_http -> {AshAuthzed.Adapters.SpiceDBHttp, merged_opts}
      :memory -> {AshAuthzed.Adapters.Memory, merged_opts}
      mod when is_atom(mod) -> {mod, merged_opts}
      other -> raise Error.new(:invalid_adapter, "Invalid adapter: #{inspect(other)}")
    end
  end
end
