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
    creator_actor = %{id: Ash.UUID.generate(), type: "user"}
    editor_actor = %{id: Ash.UUID.generate(), type: "user"}
    outsider_actor = %{id: Ash.UUID.generate(), type: "user"}

    # Grant catalog-wide `:admin` to `admin_actor` and `:can_create` to `creator_actor`
    {:ok, :synced} =
      Memory.write_tuples(
        [
          {:create, "catalog:main#admin@user:#{admin_actor.id}"},
          {:create, "catalog:main#can_create@user:#{creator_actor.id}"}
        ],
        store: AshAuthzed.Test.CapabilityMemoryStore
      )

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
      creator_actor: creator_actor,
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
    test "full admin and creator_actor (:can_create) can call create_item, while editor_actor (:can_edit) is forbidden",
         %{
           admin_actor: admin,
           creator_actor: creator,
           editor_actor: editor,
           item: item
         } do
      assert {:ok, created_by_admin} =
               AdminCapabilities.create_item(
                 %{
                   title: "Created by Admin",
                   admin_id: admin.id,
                   capability: :admin
                 },
                 actor: admin
               )

      assert created_by_admin.title == "Created by Admin"

      assert {:ok, created_by_creator} =
               AdminCapabilities.create_item(
                 %{
                   title: "Created by Creator",
                   admin_id: creator.id,
                   capability: :can_edit
                 },
                 actor: creator
               )

      assert created_by_creator.title == "Created by Creator"

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.create_item!(
          %{
            title: "Unauthorized Create",
            admin_id: editor.id,
            capability: :can_edit
          },
          actor: editor
        )
      end

      assert {:ok, updated} =
               AdminCapabilities.update_item(item, %{title: "Updated by Admin"}, actor: admin)

      assert updated.title == "Updated by Admin"
      assert :ok = AdminCapabilities.destroy_item(updated, actor: admin)
    end

    test "actor granted per-item :can_edit capability can only read and update that specific item, and cannot create or delete",
         %{
           editor_actor: editor,
           item: item
         } do
      # Seed an item where `editor` only has per-item `:can_edit` capability
      editable_item =
        Item
        |> Ash.Changeset.for_create(:create, %{
          title: "Scoped Item",
          admin_id: editor.id,
          capability: :can_edit
        })
        |> Ash.create!(authorize?: false)

      # Exact row-level filtering: per-item editor can ONLY see `editable_item` and NOT `item`
      assert {:ok, [returned_item]} = AdminCapabilities.list_items(actor: editor)
      assert returned_item.id == editable_item.id

      assert {:ok, updated} =
               AdminCapabilities.update_item(editable_item, %{title: "Edited"}, actor: editor)

      assert updated.title == "Edited"

      # Denied: per-item editor cannot update `item` ("Initial Spec")
      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.update_item!(item, %{title: "Cross-Item Edit"}, actor: editor)
      end

      # Denied: `can_edit` does NOT satisfy `admin_create` or `admin_delete`
      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.create_item!(
          %{
            title: "Unauthorized Create",
            admin_id: editor.id,
            capability: :can_edit
          },
          actor: editor
        )
      end

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.destroy_item!(updated, actor: editor)
      end
    end

    test "downgrading an actor's capability from :admin to :can_edit revokes #admin and forbids destroy_item!",
         %{admin_actor: catalog_admin} do
      item_admin = %{id: Ash.UUID.generate(), type: "user"}

      scoped_item =
        Item
        |> Ash.Changeset.for_create(:create, %{
          title: "Downgradeable Item",
          admin_id: item_admin.id,
          capability: :admin
        })
        |> Ash.create!(authorize?: false)

      # Initially `item_admin` has `:admin` on `scoped_item`, which satisfies `:admin_delete`
      assert Ash.can?({scoped_item, :destroy}, item_admin)

      # Downgrade `item_admin`'s capability from `:admin` to `:can_edit` via `update_item`
      assert {:ok, downgraded_item} =
               AdminCapabilities.update_item(
                 scoped_item,
                 %{capability: :can_edit},
                 actor: catalog_admin
               )

      assert downgraded_item.capability == :can_edit

      # Still allowed to edit, but `#admin` tuple was revoked so `destroy_item!` is immediately forbidden
      assert {:ok, _} =
               AdminCapabilities.update_item(
                 downgraded_item,
                 %{title: "Still Editable"},
                 actor: item_admin
               )

      assert_raise Ash.Error.Forbidden, fn ->
        AdminCapabilities.destroy_item!(downgraded_item, actor: item_admin)
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
