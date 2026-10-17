defmodule Mix.Tasks.AshAuthzed.BackfillTest do
  use ExUnit.Case, async: false

  alias AshAuthzed.Adapters.Memory
  alias AshAuthzed.Test.Accounts
  alias AshAuthzed.Test.User
  alias Mix.Tasks.AshAuthzed.Backfill
  alias Mix.Tasks.AshAuthzed.Bench

  setup do
    {:ok, parsed} = Licet.Validate.parse(File.read!("priv/licet/user_permissions.yaml"))
    start_supervised!({Memory, name: AshAuthzed.Test.MemoryStore, schema: parsed.schema})

    # Seed records with authorize?: false
    users =
      for {id, name, role} <- [
            {"u_root", "Root", :super_admin},
            {"u_alice", "Alice", :admin},
            {"u_bob", "Bob", :user},
            {"u_charlie", "Charlie", :user}
          ] do
        User
        |> Ash.Changeset.for_create(:create, %{id: id, name: name, role: role})
        |> Ash.create!(authorize?: false)
      end

    %{users: users}
  end

  describe "Mix.Tasks.AshAuthzed.Backfill" do
    test "backfills missing tuples, supports batch pagination, and is idempotent when run twice" do
      # Clear the memory store so we can verify backfill from a blank ReBAC state
      existing = Memory.list_tuples(AshAuthzed.Test.MemoryStore)

      {:ok, _} =
        Memory.write_tuples(
          Enum.map(existing, &{:delete, &1}),
          store: AshAuthzed.Test.MemoryStore
        )

      assert Memory.list_tuples(AshAuthzed.Test.MemoryStore) == []

      # 1. First run with small batch size (batch_size: 2 across 4 records -> 2 batches)
      output_1 =
        ExUnit.CaptureIO.capture_io(fn ->
          Backfill.run(["--resource", inspect(User), "--batch-size", "2"])
        end)

      assert output_1 =~ "Completed AshAuthzed.Test.User: 4 record(s)"
      assert output_1 =~ "across 2 batch(es)."

      tuples_after_first = Memory.list_tuples(AshAuthzed.Test.MemoryStore)
      assert "user_profile:u_root#owner@user:u_root" in tuples_after_first
      assert "platform:main#super_admin@user:u_root" in tuples_after_first
      assert "user_profile:u_root#is_protected_admin@user:*" in tuples_after_first
      assert "user_profile:u_bob#owner@user:u_bob" in tuples_after_first
      assert "platform:main#member@user:u_bob" in tuples_after_first

      # 2. Second run (idempotency): produces identical tuple set with no duplicates
      ExUnit.CaptureIO.capture_io(fn ->
        Backfill.run(["--domain", inspect(Accounts), "--batch-size", "2"])
      end)

      assert Memory.list_tuples(AshAuthzed.Test.MemoryStore) == tuples_after_first
    end

    test "supports --dry-run and --no-reconcile flags" do
      existing = Memory.list_tuples(AshAuthzed.Test.MemoryStore)

      {:ok, _} =
        Memory.write_tuples(
          Enum.map(existing, &{:delete, &1}),
          store: AshAuthzed.Test.MemoryStore
        )

      dry_output =
        ExUnit.CaptureIO.capture_io(fn ->
          Backfill.run(["--resource", inspect(User), "--dry-run", "--no-reconcile"])
        end)

      assert dry_output =~ "[DRY RUN]"
      assert Memory.list_tuples(AshAuthzed.Test.MemoryStore) == []
    end

    test "AshAuthzed.backfill_all/2 backfills all resources in a domain list" do
      assert {:ok, %{User => %{records: 4, batches: 2}}} =
               AshAuthzed.backfill_all([Accounts], batch_size: 2)
    end
  end

  describe "Mix.Tasks.AshAuthzed.Bench smoke test" do
    test "executes small-iteration benchmark dry run with --count 2 and --adapter memory" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Bench.run(["--count", "2", "--batch-size", "2", "--adapter", "memory"])
        end)

      assert output =~ "=== AshAuthzed Benchmark"
      assert output =~ "--- Benchmark Results ---"
      assert output =~ "AshAuthzed.Adapters.Memory"
    end
  end
end
