defmodule AshAuthzed.Transformer do
  @moduledoc """
  Compile-time Spark DSL transformer that:
  - Derives `relation` entities and `policy` checks directly from the `.zed` schema
    when `from_zed` is configured on the resource.
  - Attaches `AshAuthzed.SyncChange` to resource actions (`:create`, `:update`, `:destroy`).
  - Registers `@external_resource` for the configured `.zed` / YAML schema file so changes
    trigger automatic recompilation.
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshAuthzed.Verifiers.VerifyZedSchema
  alias Spark.Dsl.Extension
  alias Spark.Dsl.Transformer
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @default_policy_mappings [
    view: :read,
    read: :read,
    edit: :update,
    update: :update,
    create: :create,
    add: :create,
    delete: :destroy,
    destroy: :destroy
  ]

  @impl true
  def after?(Ash.Resource.Transformers.SetTypes), do: true
  def after?(_), do: false

  @impl true
  def before?(Ash.Policy.Authorizer.Transformers.AddMissingFieldPolicies), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    schema_path = VerifyZedSchema.schema_path(dsl_state)

    with {:ok, change} <-
           Transformer.build_entity(Ash.Resource.Dsl, [:changes], :change,
             change: AshAuthzed.SyncChange,
             on: [:create, :update, :destroy]
           ),
         {:ok, dsl_state} <- maybe_derive_from_zed(dsl_state, schema_path) do
      dsl_state =
        dsl_state
        |> Transformer.add_entity([:changes], change)
        |> maybe_register_external_resource(schema_path)

      {:ok, dsl_state}
    end
  end

  defp maybe_derive_from_zed(dsl_state, schema_path) do
    section = resolve_section(dsl_state)
    from_zed = Extension.get_opt(dsl_state, [section], :from_zed, false)

    if from_zed do
      path = resolve_from_zed_path(from_zed, schema_path)
      module = Verifier.get_persisted(dsl_state, :module)
      derive_from_schema_file(dsl_state, section, path, module)
    else
      {:ok, dsl_state}
    end
  end

  defp resolve_section(dsl_state) do
    if Extension.get_opt(dsl_state, [:rebac], :object_type, nil) != nil or
         Extension.get_opt(dsl_state, [:rebac], :from_zed, false) != false do
      :rebac
    else
      :authzed
    end
  end

  defp resolve_from_zed_path(from_zed, _schema_path) when is_binary(from_zed), do: from_zed
  defp resolve_from_zed_path(_from_zed, schema_path), do: schema_path

  defp derive_from_schema_file(dsl_state, section, path, module) do
    def_name = resolve_def_name(dsl_state, section)

    with {:ok, schema_text} <- VerifyZedSchema.load_schema_text(path, module),
         defs <- VerifyZedSchema.parse_zed_definitions(schema_text),
         {:ok, zed_def} <- fetch_zed_definition(defs, def_name, section, module) do
      dsl_state =
        dsl_state
        |> maybe_derive_relations(section, zed_def)
        |> maybe_derive_policies(section, zed_def)

      {:ok, dsl_state}
    end
  end

  defp fetch_zed_definition(defs, def_name, section, module) do
    case Map.fetch(defs, def_name) do
      {:ok, zed_def} ->
        {:ok, zed_def}

      :error ->
        {:error,
         DslError.exception(
           module: module,
           path: [section, :definition],
           message: """
           Definition #{inspect(def_name)} is not defined in your .zed schema.
           Available definitions: #{inspect(Map.keys(defs))}
           """
         )}
    end
  end

  defp resolve_def_name(dsl_state, section) do
    Extension.get_opt(dsl_state, [section], :definition, nil) ||
      Extension.get_opt(dsl_state, [section], :object_type, nil)
  end

  defp maybe_derive_relations(dsl_state, section, zed_def) do
    if Extension.get_opt(dsl_state, [section], :derive_relations, true) do
      existing_rel_names = fetch_existing_relation_names(dsl_state, section)
      attribute_names = fetch_attribute_names(dsl_state)

      Enum.reduce(zed_def.relations, dsl_state, fn rel_str, acc ->
        derive_single_relation(
          acc,
          section,
          rel_str,
          zed_def,
          existing_rel_names,
          attribute_names
        )
      end)
    else
      dsl_state
    end
  end

  defp fetch_existing_relation_names(dsl_state, section) do
    Extension.get_entities(dsl_state, [section])
    |> Enum.filter(
      &(is_struct(&1, AshAuthzed.Relation) or is_struct(&1, AshAuthzed.ConditionalWildcard))
    )
    |> Enum.map(&to_string(&1.name))
    |> MapSet.new()
  end

  defp fetch_attribute_names(dsl_state) do
    dsl_state
    |> ResourceInfo.attributes()
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp derive_single_relation(acc, section, rel_str, zed_def, existing_rel_names, attribute_names) do
    id_attr = pick_subject_id(attribute_names, rel_str)

    if MapSet.member?(existing_rel_names, rel_str) or not MapSet.member?(attribute_names, id_attr) do
      acc
    else
      inject_derived_relation(acc, section, rel_str, zed_def, id_attr)
    end
  end

  defp inject_derived_relation(acc, section, rel_str, zed_def, id_attr) do
    rel_atom = String.to_atom(rel_str)
    subject_type = Map.get(zed_def[:subjects] || %{}, rel_str, "user")

    case Transformer.build_entity(AshAuthzed, [section], :relation,
           name: rel_atom,
           subject_type: subject_type,
           subject_id: id_attr
         ) do
      {:ok, rel_entity} -> Transformer.add_entity(acc, [section], rel_entity)
      _ -> acc
    end
  end

  defp pick_subject_id(_attribute_names, rel_str), do: :"#{rel_str}_id"

  defp maybe_derive_policies(dsl_state, section, zed_def) do
    policy_mappings =
      resolve_policy_mappings(Extension.get_opt(dsl_state, [section], :derive_policies, false))

    if should_derive_policies?(policy_mappings, dsl_state) do
      policy_mappings
      |> Enum.filter(fn {perm, _action} ->
        MapSet.member?(zed_def.permissions, to_string(perm))
      end)
      |> Enum.group_by(fn {_perm, action_type} -> action_type end, fn {perm, _action} -> perm end)
      |> Enum.reduce(dsl_state, fn {action_type, perms}, acc ->
        inject_policy(acc, perms, action_type)
      end)
    else
      dsl_state
    end
  end

  defp should_derive_policies?(mappings, dsl_state) do
    mappings != [] and Ash.Policy.Authorizer in ResourceInfo.authorizers(dsl_state)
  end

  defp resolve_policy_mappings(true), do: @default_policy_mappings
  defp resolve_policy_mappings(map) when is_map(map), do: Map.to_list(map)

  defp resolve_policy_mappings(list) when is_list(list) do
    if Keyword.keyword?(list), do: list, else: []
  end

  defp resolve_policy_mappings(_), do: []

  defp inject_policy(dsl_state, perms, action_type) do
    checks =
      perms
      |> Enum.uniq()
      |> Enum.flat_map(fn perm ->
        case Transformer.build_entity(Ash.Policy.Authorizer, [:policies, :policy], :authorize_if,
               check: {AshAuthzed.Checks.Can, permission: perm}
             ) do
          {:ok, check} -> [check]
          _ -> []
        end
      end)

    case Transformer.build_entity(Ash.Policy.Authorizer, [:policies], :policy,
           condition: [{Ash.Policy.Check.ActionType, [type: List.wrap(action_type)]}],
           policies: checks
         ) do
      {:ok, policy} -> Transformer.add_entity(dsl_state, [:policies], policy)
      _ -> dsl_state
    end
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
