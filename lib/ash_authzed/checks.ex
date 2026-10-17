defmodule AshAuthzed.Checks.Can do
  @moduledoc """
  `Ash.Policy.FilterCheck` that evaluates whether the actor has a given Zanzibar permission
  on the target resource(s) via `AshAuthzed.Adapter.lookup_resources/4`.

  Works seamlessly for both collection reads (`Ash.read!`) and single-record mutations
  (`Ash.update!`, `Ash.destroy!`, `Ash.can?`).
  """

  use Ash.Policy.FilterCheck

  alias AshAuthzed.Adapter

  @impl true
  def describe(opts), do: "ReBAC permission check: #{opts[:permission]}"

  @impl true
  def filter(actor, %{resource: resource}, opts) when not is_nil(actor) do
    obj_type = AshAuthzed.get_opt(resource, :object_type, nil)
    actor_type = AshAuthzed.get_opt(resource, :actor_type, "user")
    id_attr = AshAuthzed.get_opt(resource, :id_attribute, :id)
    subject = "#{actor_type}:#{actor.id}"

    adapter_opts =
      AshAuthzed.adapter_config(
        resource,
        Keyword.drop(opts, [:permission])
      )

    case Adapter.lookup_resources(obj_type, opts[:permission], subject, adapter_opts) do
      {:ok, allowed_ids} ->
        expr(^ref(id_attr) in ^allowed_ids)

      {:error, _reason} ->
        false
    end
  end

  def filter(_, _, _), do: false
end

defmodule AshAuthzed.Checks.CanAssign do
  @moduledoc """
  `Ash.Policy.SimpleCheck` that verifies whether the actor is permitted to assign
  the new value of a given attribute on a target Zanzibar resource (e.g., `platform:main`).
  """

  use Ash.Policy.SimpleCheck

  alias AshAuthzed.Adapter

  @impl true
  def describe(opts) do
    "ReBAC role assignment check on #{opts[:on]} for #{opts[:attribute]}"
  end

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset, resource: resource}, opts)
      when not is_nil(actor) do
    actor_type = AshAuthzed.get_opt(resource, :actor_type, "user")
    subject = "#{actor_type}:#{actor.id}"
    prefix = Keyword.get(opts, :prefix, "assign_")

    adapter_opts =
      AshAuthzed.adapter_config(
        resource,
        Keyword.drop(opts, [:attribute, :on, :prefix])
      )

    case fetch_target_value(changeset, opts[:attribute]) do
      {:ok, new_val} when not is_nil(new_val) ->
        permission = "#{prefix}#{new_val}"
        Adapter.check?(opts[:on], permission, subject, adapter_opts)

      _ ->
        true
    end
  end

  def match?(_, _, _), do: false

  defp fetch_target_value(%Ash.Changeset{action_type: :create} = changeset, attribute) do
    {:ok, Ash.Changeset.get_attribute(changeset, attribute)}
  end

  defp fetch_target_value(%Ash.Changeset{} = changeset, attribute) do
    Ash.Changeset.fetch_change(changeset, attribute)
  end
end
