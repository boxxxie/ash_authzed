defmodule AshAuthzed.FromZedTest do
  use ExUnit.Case, async: true

  alias AshAuthzed.Verifiers.VerifyZedSchema
  alias Mix.Tasks.AshAuthzed.Schema.Apply, as: SchemaApplyTask
  alias Spark.Dsl.Extension

  describe "1. Schema-First Relation Derivation (from_zed)" do
    test "automatically derives relations from .zed definition when from_zed is enabled" do
      defmodule DerivedResource do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: [AshAuthzed]

        attributes do
          uuid_primary_key :id
          attribute :owner_id, :uuid
          attribute :platform_id, :uuid
        end

        authzed do
          object_type "user_profile"
          from_zed true
        end
      end

      entities = Extension.get_entities(DerivedResource, [:authzed])
      relations = Enum.filter(entities, &is_struct(&1, AshAuthzed.Relation))
      relation_names = Enum.map(relations, & &1.name)

      # In priv/licet/user_permissions.yaml, definition user_profile has relations: owner, platform
      assert :owner in relation_names
      assert :platform in relation_names

      owner_rel = Enum.find(relations, &(&1.name == :owner))
      assert owner_rel.subject_type == "user"
      # Automatically mapped to owner_id attribute on resource
      assert owner_rel.subject_id == :owner_id

      platform_rel = Enum.find(relations, &(&1.name == :platform))
      assert platform_rel.subject_type == "platform"
      assert platform_rel.subject_id == :platform_id
    end

    test "explicitly defined relations take precedence over derived ones" do
      defmodule ExplicitOverrideResource do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          extensions: [AshAuthzed]

        attributes do
          uuid_primary_key :id
          attribute :custom_owner_id, :uuid
        end

        authzed do
          object_type "user_profile"
          from_zed true
          relation :owner, subject_type: "user", subject_id: :custom_owner_id
          relation :platform, static_subject: "platform:main"
        end
      end

      entities = Extension.get_entities(ExplicitOverrideResource, [:authzed])
      relations = Enum.filter(entities, &is_struct(&1, AshAuthzed.Relation))

      # Ensure no duplicate :owner relation was generated
      assert Enum.count(relations, &(&1.name == :owner)) == 1

      owner_rel = Enum.find(relations, &(&1.name == :owner))
      assert owner_rel.subject_id == :custom_owner_id
    end

    test "raises DslError at compile time when from_zed schema path or definition is missing" do
      assert_raise Spark.Error.DslError, ~r/Authzed schema file not found/, fn ->
        defmodule MissingSchemaResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [AshAuthzed]

          attributes do
            uuid_primary_key :id
          end

          authzed do
            object_type "user_profile"
            from_zed "priv/licet/non_existent_schema.zed"
          end
        end
      end

      assert_raise Spark.Error.DslError, ~r/Definition "non_existent_def" is not defined/, fn ->
        defmodule MissingDefinitionResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [AshAuthzed]

          attributes do
            uuid_primary_key :id
          end

          authzed do
            object_type "user_profile"
            definition "non_existent_def"
            from_zed true
          end
        end
      end
    end
  end

  describe "2. Schema-First Policy Derivation (derive_policies)" do
    test "automatically derives policy checks from Zed permissions and groups by action_type" do
      defmodule DerivedPoliciesResource do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshAuthzed]

        attributes do
          uuid_primary_key :id
          attribute :owner_id, :uuid
          attribute :platform_id, :uuid
        end

        actions do
          defaults [:read, :update]
        end

        authzed do
          object_type "user_profile"
          from_zed true
          derive_policies view: :read, edit: :read, delete: :update
        end
      end

      policies = Extension.get_entities(DerivedPoliciesResource, [:policies])
      # Only 2 top-level policies should be generated (:read and :update), not 3
      assert length(policies) == 2

      all_checks =
        policies
        |> Enum.flat_map(& &1.policies)
        |> Enum.map(& &1.check)

      assert {AshAuthzed.Checks.Can, permission: :view} in all_checks
      assert {AshAuthzed.Checks.Can, permission: :edit} in all_checks
      assert {AshAuthzed.Checks.Can, permission: :delete} in all_checks
    end

    test "executes derived policies at runtime with Ash.Policy.Authorizer and Memory adapter" do
      defmodule RuntimePolicyDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          allow_unregistered? true
        end
      end

      defmodule RuntimeDerivedPolicyResource do
        use Ash.Resource,
          domain: RuntimePolicyDomain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshAuthzed]

        ets do
          private? true
        end

        attributes do
          uuid_primary_key :id
          attribute :owner_id, :uuid, allow_nil?: false, public?: true
        end

        actions do
          defaults [:read, :destroy]

          create :create do
            primary? true
            accept [:owner_id]
          end

          update :update do
            primary? true
            accept [:owner_id]
          end
        end

        authzed do
          object_type "user_profile"
          adapter :memory
          adapter_opts store: :runtime_derived_policy_store
          from_zed true
          derive_policies view: :read, edit: :read, edit: :update
          relation :platform, static_subject: "platform:main"
        end
      end

      {:ok, schema_text} =
        VerifyZedSchema.load_schema_text("priv/licet/user_permissions.yaml")

      start_supervised!({
        AshAuthzed.Adapters.Memory,
        name: :runtime_derived_policy_store, schema: schema_text
      })

      owner_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      record =
        RuntimeDerivedPolicyResource
        |> Ash.Changeset.for_create(:create, %{owner_id: owner_id})
        |> Ash.create!(authorize?: false)

      # Owner has `:view` and `:edit` permissions
      assert Ash.can?({record, :update}, %{id: owner_id}, domain: RuntimePolicyDomain)
      assert [fetched] = Ash.read!(RuntimeDerivedPolicyResource, actor: %{id: owner_id})
      assert fetched.id == record.id

      # Non-owner is forbidden
      refute Ash.can?({record, :update}, %{id: other_id}, domain: RuntimePolicyDomain)
      assert [] = Ash.read!(RuntimeDerivedPolicyResource, actor: %{id: other_id})
    end
  end

  describe "3. Runtime Schema Lifecycle (apply_schema)" do
    test "applies raw .zed strings, YAML schema files, and rejects missing file paths" do
      unique_store = :"memory_store_#{System.unique_integer([:positive])}"

      initial_schema = """
      definition user {}

      definition document {
        relation reader: user
        permission read = reader
      }
      """

      start_supervised!({
        AshAuthzed.Adapters.Memory,
        name: unique_store, schema: initial_schema
      })

      # Initial check works with reader
      assert {:ok, _} =
               AshAuthzed.Adapter.write_tuples(
                 [{:touch, "document:doc1#reader@user:alice"}],
                 adapter: :memory,
                 store: unique_store
               )

      assert AshAuthzed.Adapter.check?(
               "document:doc1",
               :read,
               "user:alice",
               adapter: :memory,
               store: unique_store
             )

      # Now apply an updated schema adding an editor relation and write permission
      updated_schema = """
      definition user {}

      definition document {
        relation reader: user
        relation editor: user
        permission read = reader + editor
        permission write = editor
      }
      """

      assert :ok =
               AshAuthzed.apply_schema(updated_schema, adapter: :memory, store: unique_store)

      assert {:ok, _} =
               AshAuthzed.Adapter.write_tuples(
                 [{:touch, "document:doc1#editor@user:bob"}],
                 adapter: :memory,
                 store: unique_store
               )

      assert AshAuthzed.Adapter.check?(
               "document:doc1",
               :write,
               "user:bob",
               adapter: :memory,
               store: unique_store
             )

      assert AshAuthzed.Adapter.check?(
               "document:doc1",
               :read,
               "user:bob",
               adapter: :memory,
               store: unique_store
             )

      # Applying a YAML validation file extracts its `schema` key properly
      assert :ok =
               AshAuthzed.apply_schema("priv/licet/user_permissions.yaml",
                 adapter: :memory,
                 store: unique_store
               )

      # Applying a non-existent file path returns an error instead of treating path as schema text
      assert {:error, %AshAuthzed.Error{reason: :schema_file_not_found}} =
               AshAuthzed.apply_schema("priv/licet/does_not_exist.zed",
                 adapter: :memory,
                 store: unique_store
               )
    end
  end

  describe "4. Mix Task (mix ash_authzed.schema.apply)" do
    test "applies schema via Mix task and raises on missing file or unknown adapter" do
      unique_store = :"mix_task_store_#{System.unique_integer([:positive])}"

      start_supervised!({
        AshAuthzed.Adapters.Memory,
        name: unique_store, schema: "definition user {}"
      })

      prev_opts = Application.get_env(:ash_authzed, :adapter_opts)
      Application.put_env(:ash_authzed, :adapter_opts, store: unique_store)

      try do
        ExUnit.CaptureIO.capture_io(fn ->
          SchemaApplyTask.run([
            "--schema",
            "priv/licet/user_permissions.yaml",
            "--adapter",
            "memory"
          ])
        end)

        assert {:ok, _} =
                 AshAuthzed.Adapter.write_tuples(
                   [{:touch, "user_profile:u1#owner@user:u1"}],
                   adapter: :memory,
                   store: unique_store
                 )

        assert AshAuthzed.Adapter.check?(
                 "user_profile:u1",
                 :view,
                 "user:u1",
                 adapter: :memory,
                 store: unique_store
               )

        assert_raise Mix.Error, ~r/Schema file not found/, fn ->
          SchemaApplyTask.run(["--schema", "priv/licet/missing.zed"])
        end

        assert_raise Mix.Error, ~r/Unknown adapter "bogus_adapter"/, fn ->
          SchemaApplyTask.run([
            "--schema",
            "priv/licet/user_permissions.yaml",
            "--adapter",
            "bogus_adapter"
          ])
        end
      after
        if prev_opts do
          Application.put_env(:ash_authzed, :adapter_opts, prev_opts)
        else
          Application.delete_env(:ash_authzed, :adapter_opts)
        end
      end
    end
  end
end
