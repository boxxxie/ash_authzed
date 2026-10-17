defmodule AshAuthzed.Checks.Can do
  @moduledoc """
  `Ash.Policy.FilterCheck` that evaluates whether the actor has a given Zanzibar permission
  on the target resource(s) via `AshAuthzed.Adapter.lookup_resources/4`, or on a static target
  object (`target: "catalog:main"` / `on: "catalog:main"`) via `AshAuthzed.Adapter.check?/4`.

  Works seamlessly for collection reads (`Ash.read!`), single-record mutations
  (`Ash.update!`, `Ash.destroy!`, `Ash.can?`), and `:create` actions when `target: "type:id"`
  (or `on: "type:id"`) is specified.
  """

  use Ash.Policy.FilterCheck

  alias Ash.Changeset.OriginalDataNotAvailable
  alias AshAuthzed.Adapter

  @impl true
  def describe(opts) do
    case opts[:target] || opts[:on] do
      nil -> "ReBAC permission check: #{opts[:permission]}"
      target -> "ReBAC permission check: #{opts[:permission]} on #{target}"
    end
  end

  @impl true
  def filter(%{id: actor_id}, %{resource: resource} = context, opts) when not is_nil(actor_id) do
    obj_type = AshAuthzed.get_opt(resource, :object_type, nil)
    actor_type = AshAuthzed.get_opt(resource, :actor_type, "user")
    id_attr = AshAuthzed.get_opt(resource, :id_attribute, :id)
    subject = "#{actor_type}:#{actor_id}"
    static_target = resolve_target(opts[:target] || opts[:on], context, obj_type, id_attr)

    adapter_opts =
      AshAuthzed.adapter_config(
        resource,
        Keyword.drop(opts, [:permission, :on, :target])
      )

    if is_binary(static_target) do
      Adapter.check?(static_target, opts[:permission], subject, adapter_opts)
    else
      case Adapter.lookup_resources(obj_type, opts[:permission], subject, adapter_opts) do
        {:ok, allowed_ids} ->
          expr(^ref(id_attr) in ^allowed_ids)

        {:error, _reason} ->
          false
      end
    end
  end

  def filter(_, _, _), do: false

  defp resolve_target(target, _context, _obj_type, _id_attr) when is_binary(target), do: target

  defp resolve_target(
         _target,
         %{changeset: %Ash.Changeset{action_type: action_type, data: data}},
         obj_type,
         id_attr
       )
       when action_type in [:update, :destroy] and is_map(data) and
              not is_struct(data, OriginalDataNotAvailable) do
    case Map.get(data, id_attr) do
      nil -> nil
      record_id -> "#{obj_type}:#{record_id}"
    end
  end

  defp resolve_target(_target, _context, _obj_type, _id_attr), do: nil
end

defmodule AshAuthzed.Checks.CanAssign do
  @moduledoc """
  `Ash.Policy.SimpleCheck` that verifies whether the actor is permitted to assign
  the new value of a given attribute on a target Zanzibar resource (e.g., `platform:main`).
  """

  use Ash.Policy.SimpleCheck

  alias Ash.Changeset.OriginalDataNotAvailable
  alias AshAuthzed.Adapter

  @impl true
  def describe(opts) do
    "ReBAC role assignment check on #{opts[:on] || opts[:target] || :self} for #{opts[:attribute]}"
  end

  @impl true
  def match?(
        %{id: actor_id},
        %{changeset: %Ash.Changeset{} = changeset, resource: resource},
        opts
      )
      when not is_nil(actor_id) do
    actor_type = AshAuthzed.get_opt(resource, :actor_type, "user")
    subject = "#{actor_type}:#{actor_id}"
    prefix = Keyword.get(opts, :permission_prefix, Keyword.get(opts, :prefix, "assign_"))
    target = resolve_assign_target(opts[:on] || opts[:target], resource, changeset)

    adapter_opts =
      AshAuthzed.adapter_config(
        resource,
        Keyword.drop(opts, [:attribute, :on, :target, :prefix, :permission_prefix])
      )

    case {target, fetch_target_value(changeset, opts[:attribute])} do
      {target_str, {:ok, new_val}} when is_binary(target_str) and not is_nil(new_val) ->
        permission = "#{prefix}#{new_val}"
        Adapter.check?(target_str, permission, subject, adapter_opts)

      {nil, {:ok, new_val}} when not is_nil(new_val) ->
        false

      _ ->
        true
    end
  end

  def match?(_, _, _), do: false

  defp resolve_assign_target(target, _resource, _changeset) when is_binary(target), do: target

  defp resolve_assign_target(target, resource, changeset) when target in [nil, :self] do
    obj_type = AshAuthzed.get_opt(resource, :object_type, nil)
    id_attr = AshAuthzed.get_opt(resource, :id_attribute, :id)

    record_id =
      case changeset.data do
        %OriginalDataNotAvailable{} ->
          Ash.Changeset.get_attribute(changeset, id_attr)

        data when is_map(data) ->
          Map.get(data, id_attr) || Ash.Changeset.get_attribute(changeset, id_attr)

        _ ->
          Ash.Changeset.get_attribute(changeset, id_attr)
      end

    if is_binary(obj_type) and not is_nil(record_id) do
      "#{obj_type}:#{record_id}"
    else
      nil
    end
  end

  defp resolve_assign_target(_target, _resource, _changeset), do: nil

  defp fetch_target_value(%Ash.Changeset{action_type: :create} = changeset, attribute) do
    {:ok, Ash.Changeset.get_attribute(changeset, attribute)}
  end

  defp fetch_target_value(%Ash.Changeset{} = changeset, attribute) do
    Ash.Changeset.fetch_change(changeset, attribute)
  end
end
