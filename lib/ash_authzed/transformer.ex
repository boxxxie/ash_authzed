defmodule AshAuthzed.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias AshAuthzed.Verifiers.VerifyZedSchema
  alias Spark.Dsl.Transformer

  @impl true
  def after?(Ash.Resource.Transformers.SetTypes), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    schema_path = VerifyZedSchema.schema_path(dsl_state)

    {:ok, change} =
      Transformer.build_entity(Ash.Resource.Dsl, [:changes], :change,
        change: AshAuthzed.SyncChange,
        on: [:create, :update, :destroy]
      )

    dsl_state =
      dsl_state
      |> Transformer.add_entity([:changes], change)
      |> maybe_register_external_resource(schema_path)

    {:ok, dsl_state}
  end

  defp maybe_register_external_resource(dsl_state, path) when is_binary(path) do
    Transformer.eval(
      dsl_state,
      [path: path],
      quote do
        @external_resource unquote(path)
      end
    )
  end

  defp maybe_register_external_resource(dsl_state, _), do: dsl_state
end

defmodule AshAuthzed.PolicyMacros do
  @moduledoc """
  Policy check macros automatically imported into Ash resources that use `AshAuthzed`.
  """

  @doc """
  Checks if the actor has `permission` on the resource in Licet / SpiceDB.
  Works for both read queries (via `lookup_resources`) and single-record mutations.
  """
  @spec rebac_can(atom() | String.t(), keyword()) :: {module(), keyword()}
  def rebac_can(permission, opts \\ []) do
    {AshAuthzed.Checks.Can, Keyword.put(opts, :permission, permission)}
  end

  @doc """
  Alias for `rebac_can/2`.
  """
  @spec authzed_can(atom() | String.t(), keyword()) :: {module(), keyword()}
  def authzed_can(permission, opts \\ []) do
    rebac_can(permission, opts)
  end

  @doc """
  Checks if the actor has permission to assign the incoming value of `attribute` on `target` (`:on`).

  For example, `rebac_can_assign(:role, on: "platform:main")` checks
  `platform:main#assign_<new_role>@user:<actor_id>`.
  """
  @spec rebac_can_assign(atom(), keyword()) :: {module(), keyword()}
  def rebac_can_assign(attribute, opts) do
    {AshAuthzed.Checks.CanAssign, Keyword.put(opts, :attribute, attribute)}
  end

  @doc """
  Alias for `rebac_can_assign/2`.
  """
  @spec authzed_can_assign(atom(), keyword()) :: {module(), keyword()}
  def authzed_can_assign(attribute, opts) do
    rebac_can_assign(attribute, opts)
  end
end
