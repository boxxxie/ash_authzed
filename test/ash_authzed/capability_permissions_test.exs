defmodule AshAuthzed.CapabilityPermissionsTest do
  use ExUnit.Case, async: true

  import Spark.Test

  alias AshAuthzed.Adapters.Memory
  alias AshAuthzed.Checks.Can
  alias AshAuthzed.Test.AdminCapabilities
  alias AshAuthzed.Test.AdminCapabilities.Item

  @validation_yaml "priv/licet/admin_capabilities.yaml"

  setup_all do
    {:ok, parsed} = Licet.Validate.parse(File.read!(@validation_yaml))

    start_supervised!(
      {Memory, name: AshAuthzed.Test.CapabilityMemoryStore, schema: parsed.schema}
    )

    :ok
  end

  setup do
    uid = System.unique_integer([:positive])
    admin_actor = %{id: Ash.UUID.generate(), type: "user"}
    editor_actor = %{id: Ash.UUID.generate(), type: "user"}
    outsider_actor = %{id: Ash.UUID.generate(), type: "user"}

    # Seed an item where `admin_actor` is the full `:admin`
    item =
      Item
      |> Ash.Changeset.for_create(:create, %{
        title: "Initial Spec #{uid}",
        admin_id: admin_actor.id,
        capability: :admin
      })
      |> Ash.create!(authorize?: false)

    %{
      uid: uid,
      admin_actor: admin_actor,
      editor_actor: editor_actor,
      outsider_actor: outsider_actor,
      item: item
    }
  end

  describe "Licet.Validate assertion suite for admin_capabilities.yaml" do
    test "passes all assertTrue and assertFalse capability assertions" do
      assert :ok = Licet.Validate.run_file(@validation_yaml)
    end
  end

  describe "admin with admin_create, admin_edit, and admin_delete capabilities" do
    test "full admin is authorized for create, read, update, and destroy", %{
      admin_actor: admin,
      item: item
    } do
      assert {:ok, created} =
               Item
               |> Ash.Changeset.for_create(:create, %{
                 title: "Created by Admin",
                 admin_id: admin.id,
                 capability: :admin
               })
               |> Ash.create(actor: admin)

      assert created.title == "Created by Admin"

      assert {:ok, updated} =
               AdminCapabilities.update_item(item, %{title: "Updated by Admin"}, actor: admin)

      assert updated.title == "Updated by Admin"
      assert :ok = AdminCapabilities.destroy_item(updated, actor: admin)
    end

    test "actor granted only admin_edit capability can update and read, but cannot create or delete",
         %{
           editor_actor: editor
         } do
      # Seed an item where `editor` only has `:can_edit` capability
      editable_item =
        Item
        |> Ash.Changeset.for_create(:create, %{
          title: "Scoped Item",
          admin_id: editor.id,
          capability: :can_edit
        })
        |> Ash.create!(authorize?: false)

      # Allowed: `can_edit` satisfies `admin_edit` for read and update
      assert {:ok, items} = AdminCapabilities.list_items(actor: editor)
      assert Enum.any?(items, &(&1.id == editable_item.id))

      assert {:ok, updated} =
               AdminCapabilities.update_item(editable_item, %{title: "Edited"}, actor: editor)

      assert updated.title == "Edited"

      # Denied: `can_edit` does NOT satisfy `admin_create` or `admin_delete`
      assert_raise Ash.Error.Forbidden, fn ->
        Item
        |> Ash.Changeset.for_create(:create, %{
          title: "Unauthorized Create",
          admin_id: editor.id,
          capability: :can_edit
        })
        |> Ash.create!(actor: editor)
      end

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.destroy_item!(updated, actor: editor)
      end
    end

    test "unauthorized actor without capabilities is denied read, update, and delete", %{
      outsider_actor: outsider,
      item: item
    } do
      # Row-level security: read returns [] for unauthorized actor
      assert {:ok, []} = AdminCapabilities.list_items(actor: outsider)

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.update_item!(item, %{title: "Hacked"}, actor: outsider)
      end

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.destroy_item!(item, actor: outsider)
      end
    end

    test "direct per-item capability grant (managed_item:<id>#can_edit@user:<id>) authorizes only that item",
         %{item: other_item} do
      scoped_actor = %{id: Ash.UUID.generate(), type: "user"}

      target_item =
        Item
        |> Ash.Changeset.for_create(:create, %{
          title: "Per-Item Scoped",
          admin_id: Ash.UUID.generate(),
          capability: :admin
        })
        |> Ash.create!(authorize?: false)

      # Grant direct per-item `can_edit` tuple on target_item only
      {:ok, :synced} =
        Memory.write_tuples(
          [{:create, "managed_item:#{target_item.id}#can_edit@user:#{scoped_actor.id}"}],
          store: AshAuthzed.Test.CapabilityMemoryStore
        )

      assert {:ok, visible} = AdminCapabilities.list_items(actor: scoped_actor)
      visible_ids = Enum.map(visible, & &1.id)
      assert target_item.id in visible_ids
      refute other_item.id in visible_ids

      assert {:ok, _} =
               AdminCapabilities.update_item(target_item, %{title: "Scoped Edit"},
                 actor: scoped_actor
               )

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.update_item!(other_item, %{title: "Forbidden Edit"},
          actor: scoped_actor
        )
      end

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.destroy_item!(target_item, actor: scoped_actor)
      end
    end

    test "nil or malformed actors fail closed without raising KeyError or BadMapError", %{
      item: item
    } do
      assert Can.filter(nil, %{resource: Item}, permission: :admin_edit) == false
      assert Can.filter(%{}, %{resource: Item}, permission: :admin_edit) == false
      assert Can.filter(%{id: nil}, %{resource: Item}, permission: :admin_edit) == false
      assert Can.filter(:invalid_actor, %{resource: Item}, permission: :admin_edit) == false

      assert {:error, %Ash.Error.Forbidden{}} = AdminCapabilities.list_items(actor: nil)

      assert {:error, %Ash.Error.Forbidden{}} =
               AdminCapabilities.list_items(actor: %{role: :unknown})

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.update_item!(item, %{title: "Nil Actor"}, actor: nil)
      end
    end
  end

  describe "compile-time capability schema verification" do
    test "VerifyZedSchema catches typos in capability names with a 'Did you mean?' suggestion" do
      error =
        assert_dsl_error do
          defmodule BrokenCapabilityItem do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              authorizers: [Ash.Policy.Authorizer],
              extensions: [AshAuthzed]

            authzed do
              object_type "managed_item"
              schema_path "priv/licet/admin_capabilities.yaml"
              relation :admin, subject_type: "user", subject_id: :admin_id
            end

            attributes do
              uuid_primary_key :id
              attribute :admin_id, :uuid
            end

            actions do
              defaults [:read, :destroy]
            end

            policies do
              policy action(:destroy) do
                # Typo: `:admin_delte` instead of `:admin_delete`
                authorize_if authzed_can(:admin_delte)
              end
            end
          end
        end

      assert error.message =~ "unknown permission `:admin_delte` on `definition managed_item`"
      assert error.message =~ "Did you mean `admin_delete`?"
    end
  end
end
