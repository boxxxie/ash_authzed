defmodule AshAuthzed.Adapters.Memory do
  @moduledoc """
  Caller-supervised in-memory Zanzibar / ReBAC adapter powered by `Licet`
  and `Licet.Schema`.

  Provides full `.zed` schema evaluation (`check`, `lookup_resources`, `write_tuples`)
  entirely in memory without requiring a running Postgres database or external
  SpiceDB daemon. Ideal for fast, isolated `async: true` unit and integration tests.

  ## Starting in a Supervision Tree or Test

      start_supervised!(
        {AshAuthzed.Adapters.Memory,
         name: MyTestAuthzed,
         schema: File.read!("priv/licet/schema.zed")}
      )
  """

  use Agent

  @behaviour AshAuthzed.Adapter

  alias AshAuthzed.Error
  alias Licet.Engine
  alias Licet.Reader.Memory, as: MemoryReader
  alias Licet.Relationship
  alias Licet.Schema

  @schema_opts NimbleOptions.new!(
                 name: [
                   type: :atom,
                   default: __MODULE__,
                   doc: "Process registration name for this memory store instance."
                 ],
                 schema: [
                   type: :any,
                   required: true,
                   doc: "A `.zed` schema string, `{:file, path}`, or compiled `%Licet.Schema{}`."
                 ],
                 relationships: [
                   type: {:list, :string},
                   default: [],
                   doc: "Initial relationship tuple strings to seed on startup."
                 ]
               )

  @doc """
  Starts an in-memory ReBAC store linked to the calling process.

  ## Options
  #{NimbleOptions.docs(@schema_opts)}
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    with {:ok, validated} <- NimbleOptions.validate(opts, @schema_opts),
         {:ok, compiled_schema} <- resolve_schema(validated[:schema]),
         {:ok, initial_tuples} <- parse_relationships(validated[:relationships]) do
      Agent.start_link(
        fn -> %{schema: compiled_schema, tuples: MapSet.new(initial_tuples)} end,
        name: validated[:name]
      )
    else
      {:error, %NimbleOptions.ValidationError{} = err} ->
        {:error, Error.new(:invalid_options, Exception.message(err))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def check(resource, permission, subject, opts) do
    server = Keyword.get(opts, :store, __MODULE__)

    with {:ok, state} <- fetch_state(server),
         {:ok, res_obj} <- parse_object(resource, false),
         {:ok, sub_obj} <- parse_object(subject, true) do
      reader = %MemoryReader{tuples: MapSet.to_list(state.tuples)}

      case Engine.check(
             state.schema,
             reader,
             revision(),
             res_obj,
             to_string(permission),
             sub_obj,
             timeout: Keyword.get(opts, :timeout, 5_000)
           ) do
        {:ok, :allowed} -> {:ok, true}
        {:ok, :denied} -> {:ok, false}
        {:error, reason} -> {:error, Error.new(:engine_check_failed, reason)}
      end
    end
  end

  @impl true
  def lookup_resources(resource_type, permission, subject, opts) do
    server = Keyword.get(opts, :store, __MODULE__)

    with {:ok, state} <- fetch_state(server),
         {:ok, sub_obj} <- parse_object(subject, true) do
      reader = %MemoryReader{tuples: MapSet.to_list(state.tuples)}

      case Engine.resource_ids(
             state.schema,
             reader,
             revision(),
             resource_type,
             to_string(permission),
             sub_obj,
             timeout: Keyword.get(opts, :timeout, 5_000)
           ) do
        {:ok, ids_set} -> {:ok, ids_set |> MapSet.to_list() |> Enum.sort()}
        {:error, reason} -> {:error, Error.new(:engine_lookup_failed, reason)}
      end
    end
  end

  @impl true
  def write_tuples(operations, opts) do
    server = Keyword.get(opts, :store, __MODULE__)

    with :ok <- ensure_started(server),
         {:ok, parsed_ops} <- parse_operations(operations) do
      Agent.update(server, fn state ->
        %{state | tuples: Enum.reduce(parsed_ops, state.tuples, &apply_operation/2)}
      end)

      {:ok, :synced}
    end
  end

  defp apply_operation({:create, rel}, acc), do: MapSet.put(acc, rel)
  defp apply_operation({:touch, rel}, acc), do: MapSet.put(acc, rel)
  defp apply_operation({:delete, rel}, acc), do: MapSet.delete(acc, rel)

  @impl true
  def apply_schema(schema_text, opts) do
    server = Keyword.get(opts, :store) || Keyword.get(opts, :name) || __MODULE__

    with :ok <- ensure_started(server),
         {:ok, compiled} <- resolve_schema(schema_text) do
      Agent.update(server, fn state ->
        Map.put(state, :schema, compiled)
      end)

      :ok
    end
  end

  @doc """
  Returns all currently stored `%Licet.Relationship{}` tuples as strings.
  """
  @spec list_tuples(atom()) :: [String.t()]
  def list_tuples(server \\ __MODULE__) do
    Agent.get(server, fn state ->
      state.tuples
      |> MapSet.to_list()
      |> Enum.map(&Relationship.to_string/1)
      |> Enum.sort()
    end)
  end

  defp resolve_schema(%{definitions: _} = schema), do: {:ok, schema}

  defp resolve_schema({:file, path}) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> resolve_schema(content)
      {:error, reason} -> {:error, Error.new(:schema_file_error, reason)}
    end
  end

  defp resolve_schema(source) when is_binary(source) do
    case Schema.parse(source) do
      {:ok, schema} -> {:ok, schema}
      {:error, reason} -> {:error, Error.new(:invalid_schema, reason)}
    end
  end

  defp parse_relationships(list) do
    Enum.reduce_while(list, {:ok, []}, fn line, {:ok, acc} ->
      case Relationship.parse(line) do
        {:ok, rel} -> {:cont, {:ok, [rel | acc]}}
        {:error, reason} -> {:halt, {:error, Error.new(:invalid_relationship, reason)}}
      end
    end)
  end

  defp parse_operations(operations) do
    Enum.reduce_while(operations, {:ok, []}, fn
      {op, %Relationship{} = rel}, {:ok, acc} when op in [:create, :touch, :delete] ->
        {:cont, {:ok, [{op, rel} | acc]}}

      {op, tuple_str}, {:ok, acc}
      when op in [:create, :touch, :delete] and is_binary(tuple_str) ->
        case Relationship.parse(tuple_str) do
          {:ok, rel} -> {:cont, {:ok, [{op, rel} | acc]}}
          {:error, reason} -> {:halt, {:error, Error.new(:invalid_relationship, reason)}}
        end

      other, _acc ->
        {:halt, {:error, Error.new(:invalid_operation, other)}}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp parse_object(text, allow_relation?) when is_binary(text) do
    {obj_part, relation} =
      case String.split(text, "#", parts: 2) do
        [obj, rel] -> {obj, rel}
        [obj] -> {obj, ""}
      end

    case String.split(obj_part, ":", parts: 2) do
      [type, id] when type != "" and id != "" ->
        if relation != "" and not allow_relation? do
          {:error, Error.new(:invalid_object, "Resource cannot include a relation: #{text}")}
        else
          {:ok, %{type: type, id: id, relation: relation}}
        end

      _ ->
        {:error, Error.new(:invalid_object, "Invalid object format: #{inspect(text)}")}
    end
  end

  defp fetch_state(server) do
    case Process.whereis(server) do
      nil -> {:error, Error.new(:not_started, "Memory store #{inspect(server)} is not running")}
      _pid -> {:ok, Agent.get(server, & &1)}
    end
  end

  defp ensure_started(server) do
    case Process.whereis(server) do
      nil -> {:error, Error.new(:not_started, "Memory store #{inspect(server)} is not running")}
      _pid -> :ok
    end
  end

  defp revision, do: %{snapshot: "0:0:", own_xid: "", at: DateTime.utc_now()}
end
