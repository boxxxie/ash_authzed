defmodule AshAuthzed.IntegrationTest do
  use ExUnit.Case, async: false

  alias AshAuthzed.Adapters.Memory
  alias AshAuthzed.Test.User
  alias Mix.Tasks.Rebac.Backfill

  setup do
    {:ok, parsed} = Licet.Validate.parse(File.read!("priv/licet/user_permissions.yaml"))

    start_supervised!({Memory, name: AshAuthzed.Test.MemoryStore, schema: parsed.schema})

    root =
      User
      |> Ash.Changeset.for_create(:create, %{id: "root", name: "Root", role: :super_admin})
      |> Ash.create!(authorize?: false)

    alice =
      User
      |> Ash.Changeset.for_create(:create, %{id: "alice", name: "Alice", role: :admin})
      |> Ash.create!(authorize?: false)

    bob =
      User
      |> Ash.Changeset.for_create(:create, %{id: "bob", name: "Bob", role: :admin})
      |> Ash.create!(authorize?: false)

    charlie =
      User
      |> Ash.Changeset.for_create(:create, %{id: "charlie", name: "Charlie", role: :user})
      |> Ash.create!(authorize?: false)

    dave =
      User
      |> Ash.Changeset.for_create(:create, %{id: "dave", name: "Dave", role: :user})
      |> Ash.create!(authorize?: false)

    %{root: root, alice: alice, bob: bob, charlie: charlie, dave: dave}
  end

  test "SyncChange automatically creates expected tuples on resource creation", %{
    alice: alice,
    charlie: charlie
  } do
    tuples = Memory.list_tuples(AshAuthzed.Test.MemoryStore)

    assert "user_profile:#{alice.id}#owner@user:#{alice.id}" in tuples
    assert "user_profile:#{alice.id}#platform@platform:main" in tuples
    assert "platform:main#admin@user:#{alice.id}" in tuples
    assert "user_profile:#{alice.id}#is_protected_admin@user:*" in tuples

    assert "user_profile:#{charlie.id}#owner@user:#{charlie.id}" in tuples
    assert "platform:main#member@user:#{charlie.id}" in tuples
    refute "user_profile:#{charlie.id}#is_protected_admin@user:*" in tuples
  end

  test "read policy filters records via lookup_resources", %{
    alice: alice,
    charlie: charlie
  } do
    # Regular user Charlie can only view their own profile
    charlie_visible = Ash.read!(User, actor: charlie)
    assert Enum.map(charlie_visible, & &1.id) == ["charlie"]

    # Admin Alice can view all profiles
    alice_visible = Ash.read!(User, actor: alice)

    assert Enum.sort(Enum.map(alice_visible, & &1.id)) == [
             "alice",
             "bob",
             "charlie",
             "dave",
             "root"
           ]
  end

  test "self-editing is allowed for all users including admins", %{
    root: root,
    alice: alice,
    charlie: charlie
  } do
    assert %{name: "Root Updated"} =
             root
             |> Ash.Changeset.for_update(:update_profile, %{name: "Root Updated"})
             |> Ash.update!(actor: root)

    assert %{name: "Alice Updated"} =
             alice
             |> Ash.Changeset.for_update(:update_profile, %{name: "Alice Updated"})
             |> Ash.update!(actor: alice)

    assert %{name: "Charlie Updated"} =
             charlie
             |> Ash.Changeset.for_update(:update_profile, %{name: "Charlie Updated"})
             |> Ash.update!(actor: charlie)
  end

  test "admin can edit and delete regular users, but NOT other admins or super_admins", %{
    root: root,
    alice: alice,
    bob: bob,
    charlie: charlie
  } do
    # Admin -> Regular User: Allowed
    assert %{name: "Charlie by Alice"} =
             charlie
             |> Ash.Changeset.for_update(:update_profile, %{name: "Charlie by Alice"})
             |> Ash.update!(actor: alice)

    # Admin -> Admin: Forbidden
    assert_raise Ash.Error.Forbidden, fn ->
      bob
      |> Ash.Changeset.for_update(:update_profile, %{name: "Hacked Bob"})
      |> Ash.update!(actor: alice)
    end

    # Admin -> Super Admin: Forbidden
    assert_raise Ash.Error.Forbidden, fn ->
      root
      |> Ash.Changeset.for_update(:update_profile, %{name: "Hacked Root"})
      |> Ash.update!(actor: alice)
    end

    # Admin cannot delete themselves
    assert_raise Ash.Error.Forbidden, fn ->
      Ash.destroy!(alice, actor: alice)
    end

    # Admin can delete Charlie
    assert :ok = Ash.destroy!(charlie, actor: alice)

    refute "user_profile:charlie#owner@user:charlie" in Memory.list_tuples(
             AshAuthzed.Test.MemoryStore
           )
  end

  test "role promotion and demotion enforces rebac_can_assign and syncs wildcard tuples", %{
    root: root,
    alice: alice,
    charlie: charlie
  } do
    # Admin Alice cannot promote Charlie to :admin
    assert_raise Ash.Error.Forbidden, fn ->
      charlie
      |> Ash.Changeset.for_update(:change_role, %{role: :admin})
      |> Ash.update!(actor: alice)
    end

    # Super Admin Root CAN promote Charlie to :admin
    promoted_charlie =
      charlie
      |> Ash.Changeset.for_update(:change_role, %{role: :admin})
      |> Ash.update!(actor: root)

    assert promoted_charlie.role == :admin

    tuples = Memory.list_tuples(AshAuthzed.Test.MemoryStore)
    assert "platform:main#admin@user:charlie" in tuples
    refute "platform:main#member@user:charlie" in tuples
    assert "user_profile:charlie#is_protected_admin@user:*" in tuples

    # Now that Charlie is a protected admin, Alice can no longer edit Charlie!
    assert_raise Ash.Error.Forbidden, fn ->
      promoted_charlie
      |> Ash.Changeset.for_update(:update_profile, %{name: "Blocked Edit"})
      |> Ash.update!(actor: alice)
    end

    # Super Admin Root demotes Charlie back to :user
    demoted_charlie =
      promoted_charlie
      |> Ash.Changeset.for_update(:change_role, %{role: :user})
      |> Ash.update!(actor: root)

    assert demoted_charlie.role == :user

    tuples_after = Memory.list_tuples(AshAuthzed.Test.MemoryStore)
    assert "platform:main#member@user:charlie" in tuples_after
    refute "platform:main#admin@user:charlie" in tuples_after
    refute "user_profile:charlie#is_protected_admin@user:*" in tuples_after

    # Alice can edit Charlie again
    assert %{name: "Editable Again"} =
             demoted_charlie
             |> Ash.Changeset.for_update(:update_profile, %{name: "Editable Again"})
             |> Ash.update!(actor: alice)
  end

  test "bulk_create, bulk_update, and bulk_destroy sync tuples in batched calls", %{
    root: root
  } do
    inputs = [
      %{id: "erin", name: "Erin", role: :user},
      %{id: "frank", name: "Frank", role: :admin}
    ]

    assert %Ash.BulkResult{status: :success} =
             Ash.bulk_create(inputs, User, :create,
               actor: root,
               return_errors?: true
             )

    tuples = Memory.list_tuples(AshAuthzed.Test.MemoryStore)
    assert "user_profile:erin#owner@user:erin" in tuples
    assert "platform:main#member@user:erin" in tuples
    refute "user_profile:erin#is_protected_admin@user:*" in tuples

    assert "user_profile:frank#owner@user:frank" in tuples
    assert "platform:main#admin@user:frank" in tuples
    assert "user_profile:frank#is_protected_admin@user:*" in tuples

    # Bulk update Erin and Frank to :admin
    import Ash.Query

    assert %Ash.BulkResult{status: :success} =
             User
             |> filter(id in ["erin", "frank"])
             |> Ash.bulk_update(:change_role, %{role: :admin},
               actor: root,
               strategy: [:stream],
               return_errors?: true
             )

    tuples_after_update = Memory.list_tuples(AshAuthzed.Test.MemoryStore)
    assert "platform:main#admin@user:erin" in tuples_after_update
    refute "platform:main#member@user:erin" in tuples_after_update
    assert "user_profile:erin#is_protected_admin@user:*" in tuples_after_update

    # Bulk destroy Erin and Frank
    assert %Ash.BulkResult{status: :success} =
             User
             |> filter(id in ["erin", "frank"])
             |> Ash.bulk_destroy(:destroy, %{},
               actor: root,
               strategy: [:stream],
               return_errors?: true
             )

    tuples_after_destroy = Memory.list_tuples(AshAuthzed.Test.MemoryStore)
    refute "user_profile:erin#owner@user:erin" in tuples_after_destroy
    refute "platform:main#admin@user:erin" in tuples_after_destroy
    refute "user_profile:frank#owner@user:frank" in tuples_after_destroy
  end

  test "build_operations handles %Ash.Changeset.OriginalDataNotAvailable{} for atomic SQL updates" do
    ops =
      AshAuthzed.SyncChange.build_operations(
        User,
        :update,
        %Ash.Changeset.OriginalDataNotAvailable{},
        %{id: "charlie", name: "Charlie", role: :admin}
      )

    # Should emit :delete for non-matching enum values (:user -> "member", :super_admin -> "super_admin")
    # and :create for the new value (:admin -> "admin") + conditional wildcard
    assert {:delete, "platform:main#member@user:charlie"} in ops
    assert {:delete, "platform:main#super_admin@user:charlie"} in ops
    assert {:create, "platform:main#admin@user:charlie"} in ops
    assert {:create, "user_profile:charlie#is_protected_admin@user:*"} in ops
  end

  describe "AshAuthzed.backfill/2 and Mix.Tasks.Rebac.Backfill" do
    test "restores missing tuples and reconciles stale out-of-band role changes", %{
      root: root,
      alice: alice,
      bob: bob
    } do
      # Initially Alice cannot edit Bob because Bob is an :admin
      refute Ash.can?({bob, :update_profile, %{name: "Edited"}}, alice)

      # Simulate an out-of-band demotion of Bob to :user in the data layer,
      # leaving Bob's stale `:admin` and `is_protected_admin@user:*` tuples in the ReBAC store
      bob_demoted =
        bob
        |> Ash.Changeset.for_update(:change_role, %{role: :user})
        |> Ash.update!(authorize?: false)

      assert bob_demoted.role == :user

      # Inject stale `:admin` and `is_protected_admin@user:*` tuples and remove `:member`
      # to simulate an out-of-band SQL update that bypassed AshAuthzed.SyncChange
      {:ok, _} =
        AshAuthzed.Adapter.write_tuples(
          [
            {:delete, "platform:main#member@user:#{bob.id}"},
            {:create, "platform:main#admin@user:#{bob.id}"},
            {:create, "user_profile:#{bob.id}#is_protected_admin@user:*"}
          ],
          AshAuthzed.adapter_config(User)
        )

      # Before backfill: ReBAC store still thinks Bob is a protected admin!
      refute Ash.can?({bob_demoted, :update_profile, %{name: "Edited"}}, alice)

      # 1. Test dry_run?: true (computes stats but does not mutate tuples)
      assert {:ok, %{records: 5, batches: 1, operations: op_count}} =
               AshAuthzed.backfill(User, batch_size: 10, dry_run?: true)

      assert op_count > 0
      refute Ash.can?({bob_demoted, :update_profile, %{name: "Edited"}}, alice)

      # 2. Run actual backfill with reconciliation
      assert {:ok, %{records: 5, batches: 3}} =
               AshAuthzed.backfill(User, batch_size: 2, reconcile?: true)

      # Now Bob's stale `:admin` and `is_protected_admin@user:*` tuples are deleted,
      # his `:member` tuple is active, and Alice (admin) CAN edit Bob!
      assert Ash.can?({bob_demoted, :update_profile, %{name: "Edited"}}, alice)
      assert Ash.can?({bob_demoted, :update_profile, %{name: "Self"}}, bob_demoted)
      assert Ash.can?({alice, :update_profile, %{name: "Root Edit"}}, root)
    end

    test "Mix.Tasks.Rebac.Backfill runs cleanly via CLI flags", %{
      charlie: charlie
    } do
      # Wipe Charlie's owner tuple manually to simulate missing ReBAC state
      {:ok, _} =
        AshAuthzed.Adapter.write_tuples(
          [{:delete, "user_profile:#{charlie.id}#owner@user:#{charlie.id}"}],
          AshAuthzed.adapter_config(User)
        )

      refute Ash.can?({charlie, :update_profile, %{name: "Self"}}, charlie)

      # Execute the Mix task targeting the User resource
      ExUnit.CaptureIO.capture_io(fn ->
        Backfill.run(["--resource", inspect(User), "--batch-size", "50"])
      end)

      # Charlie's owner tuple is restored
      assert Ash.can?({charlie, :update_profile, %{name: "Self"}}, charlie)
    end
  end
end
