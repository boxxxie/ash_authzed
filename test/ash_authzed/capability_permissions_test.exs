defmodule AshAuthzed.CapabilityPermissionsTest do
  use ExUnit.Case, async: false

  import Spark.Test

  alias AshAuthzed.Adapters.Memory
  alias AshAuthzed.Test.AdminCapabilities
  alias AshAuthzed.Test.AdminCapabilities.Item

  @validation_yaml "priv/licet/admin_capabilities.yaml"

  setup do
    {:ok, parsed} = Licet.Validate.parse(File.read!(@validation_yaml))

    start_supervised!(
      {Memory, name: AshAuthzed.Test.CapabilityMemoryStore, schema: parsed.schema}
    )

    admin_actor = %{id: Ash.UUID.generate(), type: "user"}
    editor_actor = %{id: Ash.UUID.generate(), type: "user"}
    outsider_actor = %{id: Ash.UUID.generate(), type: "user"}

    # Seed an item where `admin_actor` is the full `:admin`
    item =
      Item
      |> Ash.Changeset.for_create(:create, %{
        title: "Initial Spec",
        admin_id: admin_actor.id,
        capability: :admin
      })
      |> Ash.create!(authorize?: false)

    %{
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
    test "full admin is authorized for admin_edit and admin_delete", %{
      admin_actor: admin,
      item: item
    } do
      assert {:ok, updated} =
               AdminCapabilities.update_item(item, %{title: "Updated by Admin"}, actor: admin)

      assert updated.title == "Updated by Admin"
      assert :ok = AdminCapabilities.destroy_item(updated, actor: admin)
    end

    test "actor granted only admin_edit capability can update and read, but cannot delete", %{
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

      # Denied: `can_edit` does NOT satisfy `admin_delete`
      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.destroy_item!(updated, actor: editor)
      end
    end

    test "unauthorized actor without capabilities is denied both edit and delete", %{
      outsider_actor: outsider,
      item: item
    } do
      assert {:ok, []} = AdminCapabilities.list_items(actor: outsider)

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.update_item!(item, %{title: "Hacked"}, actor: outsider)
      end

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.destroy_item!(item, actor: outsider)
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
