defmodule AshAuthzed.SchemaVerificationTest do
  use ExUnit.Case, async: true

  alias AshAuthzed.Test.User
  alias Spark.Dsl.Extension

  @validation_yaml_path "priv/licet/user_permissions.yaml"

  setup_all do
    yaml_source = File.read!(@validation_yaml_path)
    {:ok, parsed} = Licet.Validate.parse(yaml_source)
    schema_text = extract_schema_section(yaml_source)

    %{
      yaml_source: yaml_source,
      schema_text: schema_text,
      parsed_schema: parsed.schema,
      definitions: extract_definitions(parsed.schema, schema_text)
    }
  end

  describe "1. Declarative YAML Matrix & Explain Traces" do
    test "all assertTrue and assertFalse assertions in user_permissions.yaml pass" do
      assert :ok = Licet.Validate.run_file(@validation_yaml_path)
    end

    test "wildcard exclusion `platform->admin - is_protected_admin` blocks admin-on-admin edits but never blocks self-edit or super_admin",
         %{yaml_source: yaml} do
      # 1. Alice (admin) editing Bob (admin) MUST fail because of `is_protected_admin@user:*`
      assert {:ok, :denied, trace_bob} =
               Licet.Validate.explain(yaml, "user_profile:bob#edit@user:alice")

      assert trace_bob.result == :denied

      # 2. Alice (admin) editing HERSELF (alice) MUST still pass via `owner` union branch
      #    even though `user_profile:alice#is_protected_admin@user:*` is present!
      assert {:ok, :allowed, trace_self} =
               Licet.Validate.explain(yaml, "user_profile:alice#edit@user:alice")

      assert trace_self.result == :allowed

      # 3. Root (super_admin) editing Bob (admin) MUST still pass via `platform->super_admin`
      assert {:ok, :allowed, trace_root} =
               Licet.Validate.explain(yaml, "user_profile:bob#edit@user:root")

      assert trace_root.result == :allowed
    end
  end

  describe "2. Ash Resource DSL <-> .zed Schema Drift Verification" do
    test "User resource `authzed` relations and wildcards exist in schema.zed", %{
      definitions: defs
    } do
      resource = User

      obj_type =
        Extension.get_opt(resource, [:authzed], :object_type, nil) ||
          Extension.get_opt(resource, [:rebac], :object_type, nil)

      assert Map.has_key?(defs, obj_type),
             "Resource #{inspect(resource)} specifies object_type #{inspect(obj_type)}, but it is missing from schema.zed!"

      zed_def = defs[obj_type]

      entities =
        Extension.get_entities(resource, [:authzed]) ++
          Extension.get_entities(resource, [:rebac])

      for entity <- entities do
        verify_entity_in_schema!(resource, obj_type, zed_def, defs, entity)
      end
    end

    test "every policy permission checked on User exists in schema.zed", %{
      definitions: defs
    } do
      resource = User

      obj_type =
        Extension.get_opt(resource, [:authzed], :object_type, nil) ||
          Extension.get_opt(resource, [:rebac], :object_type, nil)

      zed_def = defs[obj_type]

      for policy <- Ash.Policy.Info.policies(resource),
          %{check: {check_mod, check_opts}} <- policy.policies do
        verify_policy_check_in_schema!(resource, obj_type, zed_def, defs, check_mod, check_opts)
      end
    end
  end

  defp verify_entity_in_schema!(resource, obj_type, zed_def, _defs, %{name: rel_name})
       when not is_nil(rel_name) do
    assert MapSet.member?(zed_def.relations, to_string(rel_name)),
           "DSL relation #{inspect(rel_name)} on #{inspect(resource)} does not exist on `definition #{obj_type}` in schema.zed"
  end

  defp verify_entity_in_schema!(
         resource,
         _obj_type,
         _zed_def,
         defs,
         %{attribute: attr, target: target} = ext_role
       ) do
    [target_type, _target_id] = String.split(target, ":", parts: 2)
    target_def = Map.fetch!(defs, target_type)
    role_mapping = Map.get(ext_role, :role_mapping) || %{}

    # Verify every possible enum value for `:role` has a valid relation on `platform`
    %{constraints: constraints} = Ash.Resource.Info.attribute(resource, attr)

    for enum_val <- constraints[:one_of] || [] do
      mapped_rel =
        role_mapping
        |> Map.get(enum_val, enum_val)
        |> to_string()

      assert MapSet.member?(target_def.relations, mapped_rel),
             "Role value #{inspect(enum_val)} (mapped to #{inspect(mapped_rel)}) is missing from `definition #{target_type}` in schema.zed!"
    end
  end

  defp verify_policy_check_in_schema!(resource, obj_type, zed_def, defs, check_mod, check_opts) do
    cond do
      check_opts_has_permission?(check_mod, check_opts) ->
        perm = to_string(check_opts[:permission])

        assert MapSet.member?(zed_def.permissions, perm),
               "Policy check on #{inspect(resource)} references permission #{inspect(perm)}, which is missing from `definition #{obj_type}` in schema.zed!"

      check_opts[:attribute] && check_opts[:on] ->
        [target_type, _] = String.split(check_opts[:on], ":", parts: 2)
        target_def = Map.fetch!(defs, target_type)

        %{constraints: constraints} =
          Ash.Resource.Info.attribute(resource, check_opts[:attribute])

        for enum_val <- constraints[:one_of] || [] do
          assign_perm = "assign_#{enum_val}"

          assert MapSet.member?(target_def.permissions, assign_perm),
                 "CanAssign check requires `permission #{assign_perm}` on `definition #{target_type}` in schema.zed!"
        end

      true ->
        :ok
    end
  end

  defp check_opts_has_permission?(_mod, opts), do: Keyword.has_key?(opts, :permission)

  defp extract_definitions(%{definitions: def_map}, _schema_text) when is_map(def_map) do
    Map.new(def_map, fn {def_name, def_struct} ->
      relations =
        def_struct.relations
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      permissions =
        def_struct.permissions
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      {to_string(def_name), %{relations: relations, permissions: permissions}}
    end)
  end

  defp extract_definitions(_parsed_schema, schema_text) do
    Regex.scan(~r/definition\s+(\w+)\s*\{([^}]*)\}/s, schema_text)
    |> Map.new(fn [_, def_name, body] ->
      relations =
        Regex.scan(~r/relation\s+(\w+)\s*:/, body)
        |> Enum.map(fn [_, rel] -> rel end)
        |> MapSet.new()

      permissions =
        Regex.scan(~r/permission\s+(\w+)\s*=/, body)
        |> Enum.map(fn [_, perm] -> perm end)
        |> MapSet.new()

      {def_name, %{relations: relations, permissions: permissions}}
    end)
  end

  defp extract_schema_section(yaml_source) do
    case String.split(yaml_source, ~r/\nrelationships:\s*\|/, parts: 2) do
      [schema_part | _] -> schema_part
      _ -> yaml_source
    end
  end
end
