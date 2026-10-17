defmodule AshAuthzed.Verifiers.VerifyZedSchema do
  @moduledoc """
  Compile-time Spark verifier that cross-checks an Ash resource's `authzed` DSL
  and `policies` block against the `.zed` schema file.
  """
  use Spark.Dsl.Verifier

  alias AshAuthzed.Checks.Can
  alias AshAuthzed.Checks.CanAssign
  alias AshAuthzed.ConditionalWildcard
  alias AshAuthzed.ExternalRole
  alias AshAuthzed.Relation
  alias Licet.Schema
  alias Spark.Dsl.Extension
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    path = schema_path(dsl_state)

    with {:ok, schema_text} <- load_schema_text(path, module),
         defs <- parse_zed_definitions(schema_text),
         {:ok, obj_type, zed_def} <- verify_object_type(dsl_state, defs, module),
         :ok <- verify_entities(dsl_state, obj_type, zed_def, defs, module) do
      verify_policies(dsl_state, obj_type, zed_def, defs, module)
    end
  end

  @doc false
  def schema_path(dsl_state) do
    from_zed =
      Extension.get_opt(dsl_state, [:authzed], :from_zed, nil) ||
        Extension.get_opt(dsl_state, [:rebac], :from_zed, nil)

    if is_binary(from_zed) do
      from_zed
    else
      Extension.get_opt(dsl_state, [:authzed], :schema_path, nil) ||
        Extension.get_opt(dsl_state, [:rebac], :schema_path, nil) ||
        Application.get_env(:ash_authzed, :schema_path, "priv/licet/user_permissions.yaml")
    end
  end

  # --- 1. Load & Parse `.zed` or `.yaml` Schema ---

  @doc false
  def load_schema_text(path, module \\ nil) do
    cond do
      not File.exists?(path) ->
        {:error,
         DslError.exception(
           module: module,
           path: [:authzed],
           message: "Authzed schema file not found at #{inspect(path)}."
         )}

      String.ends_with?(path, [".yaml", ".yml"]) ->
        load_yaml_schema(path, module)

      true ->
        File.read(path)
    end
  end

  defp load_yaml_schema(path, module) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{"schema" => schema}} when is_binary(schema) ->
        {:ok, schema}

      _ ->
        {:error,
         DslError.exception(
           module: module,
           path: [:authzed],
           message: "YAML file #{inspect(path)} is missing a top-level `schema:` string key."
         )}
    end
  end

  @doc false
  def parse_zed_definitions(schema_text) do
    case Schema.parse(schema_text) do
      {:ok, %{definitions: def_map}} when is_map(def_map) ->
        Map.new(def_map, &extract_schema_definition/1)

      _ ->
        parse_zed_definitions_regex(schema_text)
    end
  end

  defp extract_schema_definition({def_name, def_struct}) do
    relations =
      def_struct.relations
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    subjects =
      Map.new(def_struct.relations, fn {rel_name, rel_def} ->
        first_subject = List.first(rel_def.subjects || [])
        type = if first_subject, do: first_subject.type, else: "user"
        {to_string(rel_name), type}
      end)

    permissions =
      def_struct.permissions
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    {to_string(def_name), %{relations: relations, permissions: permissions, subjects: subjects}}
  end

  defp parse_zed_definitions_regex(schema_text) do
    stripped = String.replace(schema_text, ~r{//[^\n]*|/\*.*?\*/}s, "")

    Regex.scan(~r/definition\s+([\w\/]+)\s*\{([^}]*)\}/s, stripped)
    |> Map.new(fn [_, def_name, body] ->
      rel_matches = Regex.scan(~r/relation\s+(\w+)\s*:\s*([\w\/]+)/, body)

      relations =
        rel_matches
        |> Enum.map(fn [_, rel, _] -> rel end)
        |> MapSet.new()

      subjects =
        rel_matches
        |> Map.new(fn [_, rel, sub] -> {rel, sub} end)

      permissions =
        Regex.scan(~r/permission\s+(\w+)\s*=/, body)
        |> Enum.map(fn [_, perm] -> perm end)
        |> MapSet.new()

      {def_name, %{relations: relations, permissions: permissions, subjects: subjects}}
    end)
  end

  # --- 2. Verify `object_type` / `definition` ---

  defp verify_object_type(dsl_state, defs, module) do
    obj_type =
      Extension.get_opt(dsl_state, [:authzed], :definition, nil) ||
        Extension.get_opt(dsl_state, [:rebac], :definition, nil) ||
        Extension.get_opt(dsl_state, [:authzed], :object_type, nil) ||
        Extension.get_opt(dsl_state, [:rebac], :object_type, nil)

    case Map.fetch(defs, obj_type) do
      {:ok, zed_def} ->
        {:ok, obj_type, zed_def}

      :error ->
        {:error,
         DslError.exception(
           module: module,
           path: [:authzed, :object_type],
           message: """
           object_type #{inspect(obj_type)} is not defined in your .zed schema.
           Available definitions: #{inspect(Map.keys(defs))}#{did_you_mean(obj_type, Map.keys(defs))}
           """
         )}
    end
  end

  # --- 3. Verify `relation`, `conditional_wildcard`, and `external_role` Entities ---

  defp verify_entities(dsl_state, obj_type, zed_def, defs, module) do
    entities =
      Extension.get_entities(dsl_state, [:authzed]) ++
        Extension.get_entities(dsl_state, [:rebac])

    Enum.reduce_while(entities, :ok, fn entity, :ok ->
      case verify_entity(entity, dsl_state, obj_type, zed_def, defs, module) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_entity(%Relation{name: rel_name} = rel, dsl_state, obj_type, zed_def, _defs, module) do
    path = [:authzed, :relation, rel_name]

    with :ok <- verify_relation_in_schema(rel_name, obj_type, zed_def, path, module) do
      verify_relation_subject(rel, dsl_state, path, module)
    end
  end

  defp verify_entity(
         %ConditionalWildcard{name: rel_name, attribute: attr},
         dsl_state,
         obj_type,
         zed_def,
         _defs,
         module
       ) do
    path = [:authzed, :conditional_wildcard, rel_name]

    with :ok <- verify_relation_in_schema(rel_name, obj_type, zed_def, path, module) do
      verify_attribute_exists(dsl_state, attr, path, module)
    end
  end

  defp verify_entity(
         %ExternalRole{attribute: attr, target: target, subject_id: s_id} = ext_role,
         dsl_state,
         obj_type,
         zed_def,
         defs,
         module
       ) do
    role_mapping = Map.get(ext_role, :role_mapping) || %{}
    path = [:authzed, :external_role, attr]

    with :ok <- verify_attribute_exists(dsl_state, s_id, path, module),
         {:ok, target_type, target_def} <-
           resolve_external_role_target(target, obj_type, zed_def, defs, path, module),
         {:ok, enum_vals} <- fetch_attribute_enum_values(dsl_state, attr, path, module) do
      verify_external_role_values(enum_vals, role_mapping, target_def, target_type, attr, module)
    end
  end

  defp verify_relation_subject(
         %Relation{static_subject: static_subj},
         _dsl_state,
         path,
         module
       )
       when is_binary(static_subj) do
    with {:ok, _type} <- parse_target_type(static_subj, path, module), do: :ok
  end

  defp verify_relation_subject(
         %Relation{subject_type: s_type, subject_id: s_id},
         dsl_state,
         path,
         module
       )
       when is_binary(s_type) and not is_nil(s_id) do
    verify_attribute_exists(dsl_state, s_id, path, module)
  end

  defp verify_relation_subject(%Relation{name: rel_name}, _dsl_state, path, module) do
    {:error,
     DslError.exception(
       module: module,
       path: path,
       message:
         "Relation `:#{rel_name}` must specify either `static_subject: \"type:id\"` or both `subject_type` and `subject_id`."
     )}
  end

  defp verify_relation_in_schema(rel_name, obj_type, zed_def, path, module) do
    rel_str = to_string(rel_name)

    if MapSet.member?(zed_def.relations, rel_str) do
      :ok
    else
      {:error,
       DslError.exception(
         module: module,
         path: path,
         message: """
         Relation `:#{rel_name}` does not exist on `definition #{obj_type}` in your .zed schema.
         Defined relations on #{obj_type}: #{inspect(MapSet.to_list(zed_def.relations))}#{did_you_mean(rel_str, zed_def.relations)}
         """
       )}
    end
  end

  defp resolve_external_role_target(target, obj_type, zed_def, _defs, _path, _module)
       when target in [nil, :self] do
    {:ok, obj_type, zed_def}
  end

  defp resolve_external_role_target(target, _obj_type, _zed_def, defs, path, module)
       when is_binary(target) do
    with {:ok, target_type} <- parse_target_type(target, path, module),
         {:ok, target_def} <- fetch_target_def(defs, target_type, path, module) do
      {:ok, target_type, target_def}
    end
  end

  defp verify_external_role_values(enum_vals, role_mapping, target_def, target_type, attr, module) do
    Enum.reduce_while(enum_vals, :ok, fn val, :ok ->
      mapped_rel =
        role_mapping
        |> Map.get(val, val)
        |> to_string()

      if MapSet.member?(target_def.relations, mapped_rel) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          DslError.exception(
            module: module,
            path: [:authzed, :external_role, attr],
            message: """
            Attribute `:#{attr}` allows value `:#{val}` (mapped to relation #{inspect(mapped_rel)}),
            but `relation #{mapped_rel}` is missing on `definition #{target_type}` in your .zed schema.
            Defined relations on #{target_type}: #{inspect(MapSet.to_list(target_def.relations))}#{did_you_mean(mapped_rel, target_def.relations)}
            """
          )}}
      end
    end)
  end

  # --- 4. Verify `policies` Checks (`authzed_can` & `authzed_can_assign`) ---

  defp verify_policies(dsl_state, obj_type, zed_def, defs, module) do
    policies = Extension.get_entities(dsl_state, [:policies])

    checks =
      for policy <- policies,
          cond_expr <- List.wrap(Map.get(policy, :policies, [])) do
        cond_expr.check
      end

    Enum.reduce_while(checks, :ok, fn
      {check_mod, opts}, :ok when check_mod in [Can, CanAssign] and is_list(opts) ->
        case verify_policy_check(check_mod, opts, dsl_state, obj_type, zed_def, defs, module) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end

      _, :ok ->
        {:cont, :ok}
    end)
  end

  defp verify_policy_check(Can, opts, _dsl_state, obj_type, zed_def, defs, module) do
    static_target = opts[:target] || opts[:on]
    path = [:policies, :policy, :authorize_if]

    if is_binary(static_target) do
      with {:ok, target_type} <- parse_target_type(static_target, path, module),
           {:ok, target_def} <- fetch_target_def(defs, target_type, path, module) do
        verify_permission_check(opts[:permission], target_type, target_def, module)
      end
    else
      verify_permission_check(opts[:permission], obj_type, zed_def, module)
    end
  end

  defp verify_policy_check(CanAssign, opts, dsl_state, obj_type, zed_def, defs, module) do
    static_target = opts[:target] || opts[:on]
    verify_can_assign_check(opts, static_target, dsl_state, obj_type, zed_def, defs, module)
  end

  defp verify_permission_check(permission, obj_type, zed_def, module) do
    perm_str = to_string(permission)
    valid_set = MapSet.union(zed_def.permissions, zed_def.relations)

    if MapSet.member?(valid_set, perm_str) do
      :ok
    else
      {:error,
       DslError.exception(
         module: module,
         path: [:policies, :policy, :authorize_if],
         message: """
         Policy check references unknown permission `:#{perm_str}` on `definition #{obj_type}`.
         Defined permissions on #{obj_type}: #{inspect(MapSet.to_list(zed_def.permissions))}#{did_you_mean(perm_str, valid_set)}
         """
       )}
    end
  end

  defp verify_can_assign_check(opts, static_target, dsl_state, obj_type, zed_def, defs, module) do
    attr = opts[:attribute]
    prefix = Keyword.get(opts, :permission_prefix, Keyword.get(opts, :prefix, "assign_"))
    path = [:policies, :policy, :authorize_if]

    with {:ok, target_type, target_def} <-
           resolve_external_role_target(static_target, obj_type, zed_def, defs, path, module),
         {:ok, enum_vals} <-
           fetch_attribute_enum_values(dsl_state, attr, [:policies, :policy], module) do
      verify_assign_permissions(enum_vals, prefix, target_def, target_type, attr, module)
    end
  end

  defp verify_assign_permissions(enum_vals, prefix, target_def, target_type, attr, module) do
    Enum.reduce_while(enum_vals, :ok, fn val, :ok ->
      assign_perm = "#{prefix}#{val}"

      if MapSet.member?(target_def.permissions, assign_perm) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          DslError.exception(
            module: module,
            path: [:policies, :policy, :authorize_if],
            message: """
            CanAssign policy check on `:#{attr}` requires `permission #{assign_perm}` on `definition #{target_type}`,
            but it is missing in your .zed schema.
            Defined permissions on #{target_type}: #{inspect(MapSet.to_list(target_def.permissions))}#{did_you_mean(assign_perm, target_def.permissions)}
            """
          )}}
      end
    end)
  end

  # --- Helpers & "Did You Mean?" Jaro Distance ---

  defp parse_target_type(target, path, module) when is_binary(target) do
    case String.split(target, ":", parts: 2) do
      [target_type, target_id] when target_type != "" and target_id != "" ->
        {:ok, target_type}

      _ ->
        {:error,
         DslError.exception(
           module: module,
           path: path,
           message:
             "Invalid target format #{inspect(target)}. Expected `\"type:id\"` (e.g. `\"platform:main\"`)."
         )}
    end
  end

  defp fetch_target_def(defs, target_type, path, module) do
    case Map.fetch(defs, target_type) do
      {:ok, target_def} ->
        {:ok, target_def}

      :error ->
        {:error,
         DslError.exception(
           module: module,
           path: path,
           message: """
           Target definition #{inspect(target_type)} does not exist in your .zed schema.
           Available definitions: #{inspect(Map.keys(defs))}#{did_you_mean(target_type, Map.keys(defs))}
           """
         )}
    end
  end

  defp verify_attribute_exists(dsl_state, attr_name, path, module) do
    attributes = Extension.get_entities(dsl_state, [:attributes])

    if Enum.any?(attributes, &(&1.name == attr_name)) do
      :ok
    else
      {:error,
       DslError.exception(
         module: module,
         path: path,
         message: "Referenced attribute `:#{attr_name}` does not exist on #{inspect(module)}."
       )}
    end
  end

  defp fetch_attribute_enum_values(dsl_state, attr_name, path, module) do
    attributes = Extension.get_entities(dsl_state, [:attributes])

    case Enum.find(attributes, &(&1.name == attr_name)) do
      nil ->
        {:error,
         DslError.exception(
           module: module,
           path: path,
           message: "Referenced attribute `:#{attr_name}` does not exist on #{inspect(module)}."
         )}

      %{constraints: constraints, type: type} ->
        vals =
          cond do
            is_list(constraints[:one_of]) -> constraints[:one_of]
            function_exported?(type, :values, 0) -> type.values()
            true -> []
          end

        {:ok, vals}
    end
  end

  defp did_you_mean(nil, _candidates), do: ""

  defp did_you_mean(target, candidates) do
    target_str = to_string(target)

    best_match =
      candidates
      |> Enum.map(&to_string/1)
      |> Enum.map(fn cand -> {cand, String.jaro_distance(target_str, cand)} end)
      |> Enum.filter(fn {_cand, score} -> score >= 0.75 end)
      |> Enum.max_by(fn {_cand, score} -> score end, fn -> nil end)

    case best_match do
      {suggestion, _score} -> "\n\nDid you mean `#{suggestion}`?"
      nil -> ""
    end
  end
end
