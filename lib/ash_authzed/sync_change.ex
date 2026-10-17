defmodule AshAuthzed.SyncChange do
  @moduledoc """
  Synchronizes Ash resource lifecycle changes to Zanzibar/ReBAC relationship tuples.

  Supports:
  - Single-record actions via `change/3` (`after_action/2`)
  - Atomic single updates via `atomic/3`
  - Bulk creates, updates, and destroys via `batch_change/3` + `after_batch/3`
    (executes a single batched `write_tuples/2` call per chunk)
  """

  use Ash.Resource.Change

  alias Ash.Changeset.OriginalDataNotAvailable
  alias Ash.Resource.Info
  alias AshAuthzed.Adapter
  alias AshAuthzed.ConditionalWildcard
  alias AshAuthzed.ExternalRole
  alias AshAuthzed.Relation

  @impl true
  def batch_callbacks?(_changesets_or_query, _opts, _context), do: true

  # 1. Single-Record Fallback (Used only when Ash does not take the batch path)
  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      ops =
        build_operations(
          changeset.resource,
          changeset.action.type,
          changeset.data,
          record
        )

      adapter_opts = AshAuthzed.adapter_config(changeset.resource, opts)

      case Adapter.write_tuples(ops, adapter_opts) do
        {:ok, _token} -> {:ok, record}
        :ok -> {:ok, record}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # 2. Batch Interception: Return changesets untouched so we don't attach
  #    N separate `after_action` callbacks when `after_batch/3` will run!
  @impl true
  def batch_change(changesets, _opts, _context) do
    changesets
  end

  # 3. Atomic Support: Return `:ok` so Ash runs `after_batch/3` once for all updated/destroyed
  #    records (both single atomic updates and bulk atomic updates/destroys) instead of attaching
  #    redundant per-record `after_action` hooks on the atomic changeset!
  @impl true
  def atomic(_changeset, _opts, _context) do
    :ok
  end

  # 4. Single Batched Write for `bulk_create`, `bulk_update`, and `bulk_destroy`
  @impl true
  def after_batch([], _opts, _context), do: :ok

  def after_batch([{first_changeset, _} | _] = changesets_and_results, opts, _context) do
    all_operations =
      changesets_and_results
      |> Enum.flat_map(fn {changeset, record} ->
        build_operations(
          changeset.resource,
          changeset.action.type,
          changeset.data,
          record
        )
      end)
      |> deduplicate_batch_ops()

    adapter_opts = AshAuthzed.adapter_config(first_changeset.resource, opts)

    case Adapter.write_tuples(all_operations, adapter_opts) do
      {:ok, _token} -> :ok
      :ok -> :ok
      {:error, reason} -> Enum.map(changesets_and_results, fn _ -> {:error, reason} end)
    end
  end

  @doc """
  Generates deduplicated tuple operations for a list of Ash resource structs.

  If `reconcile?: true` is passed (default), it treats records as an atomic update
  with `%Ash.Changeset.OriginalDataNotAvailable{}` so any stale external_role tuples
  are idempotently deleted alongside creating current tuples.
  """
  @spec operations_for_records([struct()], keyword()) :: [Adapter.operation()]
  def operations_for_records(records, opts \\ []) when is_list(records) do
    reconcile? = Keyword.get(opts, :reconcile?, true)
    action_type = if reconcile?, do: :update, else: :create
    old_record = if reconcile?, do: %OriginalDataNotAvailable{}, else: nil

    records
    |> Enum.flat_map(fn %resource{} = record ->
      build_operations(resource, action_type, old_record, record)
    end)
    |> deduplicate_batch_ops()
  end

  @doc """
  Computes the list of `{:create | :delete, tuple_string}` operations for a transition
  from `old_record` to `new_record` on `resource` for `action_type` (`:create`, `:update`, `:destroy`).
  """
  @spec build_operations(Ash.Resource.t(), atom(), map() | nil, map()) :: [Adapter.operation()]
  def build_operations(resource, action_type, old_record, new_record) do
    obj_type = AshAuthzed.get_opt(resource, :object_type, nil)
    id_attr = AshAuthzed.get_opt(resource, :id_attribute, :id)
    entities = AshAuthzed.get_entities(resource)
    record_id = Map.get(new_record, id_attr)
    obj_prefix = "#{obj_type}:#{record_id}"

    Enum.flat_map(
      entities,
      &build_entity_ops(&1, resource, obj_prefix, action_type, {old_record, new_record})
    )
  end

  defp build_entity_ops(
         %Relation{name: rel, static_subject: subj},
         _resource,
         obj_prefix,
         action_type,
         _records
       )
       when is_binary(subj) do
    op = if action_type == :destroy, do: :delete, else: :create
    [{op, "#{obj_prefix}##{rel}@#{subj}"}]
  end

  defp build_entity_ops(
         %Relation{name: rel, subject_type: s_type, subject_id: field},
         _resource,
         obj_prefix,
         :update,
         {old_record, new_record}
       )
       when is_map(old_record) and not is_struct(old_record, OriginalDataNotAvailable) do
    old_val = Map.get(old_record, field)
    new_val = Map.get(new_record, field)

    if not is_nil(old_val) and old_val != new_val do
      [
        {:delete, "#{obj_prefix}##{rel}@#{s_type}:#{old_val}"},
        {:create, "#{obj_prefix}##{rel}@#{s_type}:#{new_val}"}
      ]
    else
      [{:create, "#{obj_prefix}##{rel}@#{s_type}:#{new_val}"}]
    end
  end

  defp build_entity_ops(
         %Relation{name: rel, subject_type: s_type, subject_id: field},
         _resource,
         obj_prefix,
         action_type,
         {_old_record, new_record}
       ) do
    op = if action_type == :destroy, do: :delete, else: :create
    val = Map.get(new_record, field)
    [{op, "#{obj_prefix}##{rel}@#{s_type}:#{val}"}]
  end

  defp build_entity_ops(
         %ExternalRole{} = ext_role,
         resource,
         obj_prefix,
         action_type,
         {old_record, new_record}
       ) do
    build_external_role_ops(resource, obj_prefix, action_type, old_record, new_record, ext_role)
  end

  defp build_entity_ops(
         %ConditionalWildcard{
           name: rel,
           subject_type: s_type,
           attribute: attr,
           in: allowed_list
         },
         _resource,
         obj_prefix,
         action_type,
         {_old_record, new_record}
       ) do
    tuple = "#{obj_prefix}##{rel}@#{s_type}:*"
    qualifies? = Map.get(new_record, attr) in allowed_list

    if action_type != :destroy and qualifies? do
      [{:create, tuple}]
    else
      [{:delete, tuple}]
    end
  end

  defp build_external_role_ops(
         resource,
         obj_prefix,
         action_type,
         old_record,
         new_record,
         %ExternalRole{
           attribute: attr,
           target: target,
           subject_type: s_type,
           subject_id: field,
           role_mapping: mapping
         }
       ) do
    resolved_target =
      if target in [nil, :self] do
        obj_prefix
      else
        target
      end

    subj = "#{s_type}:#{Map.get(new_record, field)}"
    new_val = Map.get(new_record, attr)
    new_rel = map_role(new_val, mapping)

    external_role_transition_ops(
      resource,
      action_type,
      old_record,
      attr,
      resolved_target,
      subj,
      {new_val, new_rel, mapping}
    )
  end

  defp external_role_transition_ops(
         _resource,
         :destroy,
         _old_record,
         _attr,
         target,
         subj,
         {_new_val, new_rel, _mapping}
       )
       when not is_nil(new_rel) do
    [{:delete, "#{target}##{new_rel}@#{subj}"}]
  end

  defp external_role_transition_ops(
         resource,
         _action_type,
         %OriginalDataNotAvailable{},
         attr,
         target,
         subj,
         {new_val, new_rel, mapping}
       )
       when not is_nil(new_rel) do
    other_vals = possible_attribute_values(resource, attr) -- [new_val]

    delete_ops =
      other_vals
      |> Enum.map(&map_role(&1, mapping))
      |> Enum.reject(&(&1 == nil or &1 == new_rel))
      |> Enum.uniq()
      |> Enum.map(&{:delete, "#{target}##{&1}@#{subj}"})

    delete_ops ++ [{:create, "#{target}##{new_rel}@#{subj}"}]
  end

  defp external_role_transition_ops(
         _resource,
         :update,
         old_record,
         attr,
         target,
         subj,
         {_new_val, new_rel, mapping}
       )
       when is_map(old_record) and not is_nil(new_rel) do
    old_val = Map.get(old_record, attr)
    old_rel = map_role(old_val, mapping)

    if not is_nil(old_rel) and old_rel != new_rel do
      [
        {:delete, "#{target}##{old_rel}@#{subj}"},
        {:create, "#{target}##{new_rel}@#{subj}"}
      ]
    else
      [{:create, "#{target}##{new_rel}@#{subj}"}]
    end
  end

  defp external_role_transition_ops(
         _resource,
         _action_type,
         _old_record,
         _attr,
         target,
         subj,
         {_new_val, new_rel, _mapping}
       )
       when not is_nil(new_rel) do
    [{:create, "#{target}##{new_rel}@#{subj}"}]
  end

  defp external_role_transition_ops(
         _resource,
         _action_type,
         _old_record,
         _attr,
         _target,
         _subj,
         _role_info
       ),
       do: []

  @doc false
  @spec possible_attribute_values(Ash.Resource.t(), atom()) :: [term()]
  def possible_attribute_values(resource, attr_name) do
    case Info.attribute(resource, attr_name) do
      %{constraints: constraints, type: type} ->
        extract_possible_values(constraints, type)

      _ ->
        []
    end
  end

  defp extract_possible_values(constraints, type) do
    cond do
      is_list(constraints[:one_of]) ->
        constraints[:one_of]

      function_exported?(type, :values, 0) ->
        type.values()

      true ->
        []
    end
  end

  @doc false
  @spec deduplicate_batch_ops([Adapter.operation()]) :: [Adapter.operation()]
  def deduplicate_batch_ops(operations) do
    operations
    |> Enum.reduce(%{}, fn {op, tuple}, acc ->
      Map.put(acc, tuple, op)
    end)
    |> Enum.map(fn {tuple, op} -> {op, tuple} end)
  end

  defp map_role(nil, _mapping), do: nil

  defp map_role(val, mapping) when is_map(mapping) do
    Map.get(mapping, val) || Map.get(mapping, to_string(val)) || to_string(val)
  end
end
