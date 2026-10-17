defmodule AshAuthzed.BatchTelemetryTest do
  use ExUnit.Case, async: false

  import Ash.Query

  alias AshAuthzed.Adapters.Memory
  alias AshAuthzed.Test.User

  setup context do
    {:ok, parsed} = Licet.Validate.parse(File.read!("priv/licet/user_permissions.yaml"))
    start_supervised!({Memory, name: AshAuthzed.Test.MemoryStore, schema: parsed.schema})

    test_pid = self()
    handler_id = "ash-authzed-telemetry-#{inspect(context.test)}"

    :telemetry.attach(
      handler_id,
      [:ash_authzed, :adapter, :write_tuples],
      fn _event, %{tuple_count: count}, %{operations: ops}, _config ->
        send(test_pid, {:write_tuples_called, count, ops})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Seed root super_admin and flush its setup telemetry message
    root =
      User
      |> Ash.Changeset.for_create(:create, %{
        id: "root",
        name: "Root",
        role: :super_admin
      })
      |> Ash.create!(authorize?: false)

    assert_receive {:write_tuples_called, _, _}

    %{root: root}
  end

  describe "after_batch/3 single-call verification" do
    test "Ash.bulk_create! with 6 records in 1 batch emits exactly 1 write_tuples call", %{
      root: root
    } do
      inputs =
        for i <- 1..6 do
          %{
            id: "user#{i}",
            name: "User #{i}",
            role: if(rem(i, 2) == 0, do: :admin, else: :user)
          }
        end

      result =
        Ash.bulk_create!(inputs, User, :create,
          actor: root,
          batch_size: 10,
          return_records?: true,
          transaction: :all
        )

      assert result.status == :success
      assert length(result.records) == 6

      # 6 users * 4 tuple ops per user = 24 ops in a SINGLE call!
      assert_receive {:write_tuples_called, 24, ops}
      refute_receive {:write_tuples_called, _, _}

      # Verify 3 admins got `:create` for `is_protected_admin@user:*` and 3 members got `:delete`
      protected_creates =
        Enum.filter(ops, fn {op, tuple} ->
          op == :create and String.ends_with?(tuple, "#is_protected_admin@user:*")
        end)

      protected_deletes =
        Enum.filter(ops, fn {op, tuple} ->
          op == :delete and String.ends_with?(tuple, "#is_protected_admin@user:*")
        end)

      assert length(protected_creates) == 3
      assert length(protected_deletes) == 3

      # Verify role_mapping translated `:user` -> `"member"`
      member_creates =
        Enum.filter(ops, fn {op, tuple} ->
          op == :create and String.starts_with?(tuple, "platform:main#member@user:")
        end)

      assert length(member_creates) == 3
    end

    test "Ash.bulk_create! respects batch_size and emits exactly 1 call per chunk", %{
      root: root
    } do
      inputs =
        for i <- 1..5 do
          %{id: "chunk#{i}", name: "Chunk #{i}", role: :user}
        end

      # 5 records with batch_size: 2 -> 3 batches (2, 2, 1)
      Ash.bulk_create!(inputs, User, :create,
        actor: root,
        batch_size: 2,
        transaction: :batch
      )

      assert_receive {:write_tuples_called, 8, _batch_1}
      assert_receive {:write_tuples_called, 8, _batch_2}
      assert_receive {:write_tuples_called, 4, _batch_3}
      refute_receive {:write_tuples_called, _, _}
    end

    test "atomic Ash.bulk_update! handles %OriginalDataNotAvailable{} in 1 batch call", %{
      root: root
    } do
      inputs = [
        %{id: "m1", name: "M1", role: :user},
        %{id: "m2", name: "M2", role: :user}
      ]

      %{records: [u1, u2]} =
        Ash.bulk_create!(inputs, User, :create,
          actor: root,
          return_records?: true,
          authorize?: false
        )

      # Flush the bulk_create telemetry message
      assert_receive {:write_tuples_called, _, _}

      # Run atomic bulk update (`changeset.data` is `%Ash.Changeset.OriginalDataNotAvailable{}`)
      User
      |> filter(id in ^[u1.id, u2.id])
      |> Ash.bulk_update!(:change_role, %{role: :admin},
        actor: root,
        strategy: :atomic_batches,
        return_records?: true,
        transaction: :all
      )

      # Must emit ONLY 1 write_tuples call for both updated records!
      assert_receive {:write_tuples_called, _count, ops}
      refute_receive {:write_tuples_called, _, _}

      # For u1, verify that because original data wasn't preloaded, it emitted
      # idempotent `:delete` for `:member` and `:super_admin`, and `:create` for `:admin`
      assert {:delete, "platform:main#member@user:#{u1.id}"} in ops
      assert {:delete, "platform:main#super_admin@user:#{u1.id}"} in ops
      assert {:create, "platform:main#admin@user:#{u1.id}"} in ops
      assert {:create, "user_profile:#{u1.id}#is_protected_admin@user:*"} in ops
    end

    test "Ash.bulk_destroy! removes all tuples in 1 batch call", %{root: root} do
      %{records: [u1, u2]} =
        Ash.bulk_create!(
          [
            %{id: "d1", name: "D1", role: :user},
            %{id: "d2", name: "D2", role: :admin}
          ],
          User,
          :create,
          return_records?: true,
          authorize?: false
        )

      assert_receive {:write_tuples_called, _, _}

      User
      |> filter(id in ^[u1.id, u2.id])
      |> Ash.bulk_destroy!(:destroy, %{},
        actor: root,
        strategy: [:stream, :atomic_batches],
        return_records?: true,
        transaction: :all
      )

      assert_receive {:write_tuples_called, _count, ops}
      refute_receive {:write_tuples_called, _, _}

      # Every single operation on destroy must be a `:delete`
      assert Enum.all?(ops, fn {op, _tuple} -> op == :delete end)
      assert {:delete, "user_profile:#{u1.id}#owner@user:#{u1.id}"} in ops
      assert {:delete, "platform:main#admin@user:#{u2.id}"} in ops
    end
  end
end
