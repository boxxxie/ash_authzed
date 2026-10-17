defmodule AshAuthzed.AdaptersContractTest do
  use ExUnit.Case, async: true

  alias AshAuthzed.Adapter
  alias AshAuthzed.Adapters.Licet, as: LicetAdapter
  alias AshAuthzed.Adapters.Memory
  alias AshAuthzed.Error

  @schema_zed """
  definition user {}

  definition group {
    relation member: user
  }

  definition document {
    relation owner: user
    relation viewer: user | group#member | user:*

    permission view = owner + viewer
    permission edit = owner
  }
  """

  describe "AshAuthzed.Error" do
    test "formats exception messages with nil, string, and structured details" do
      err_nil = Error.new(:not_started)
      assert Exception.message(err_nil) == "AshAuthzed error: :not_started"

      err_str = Error.new(:invalid_object, "Expected type:id")
      assert Exception.message(err_str) == "AshAuthzed error (invalid_object): Expected type:id"

      err_map = Error.new(:spicedb_http_error, %{status: 500})
      assert Exception.message(err_map) =~ "AshAuthzed error (spicedb_http_error): %{status: 500}"
    end
  end

  describe "AshAuthzed.Adapter unified dispatcher" do
    test "check?/4, lookup_resources!/4, write_tuples/2, and resolve_adapter/1" do
      store = :"memory_dispatch_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: store, schema: @schema_zed})

      opts = [adapter: :memory, adapter_opts: [store: store]]

      assert {:ok, :noop} = Adapter.write_tuples([], opts)

      assert {:ok, :synced} =
               Adapter.write_tuples([{:create, "document:doc1#owner@user:alice"}], opts)

      assert Adapter.check?("document:doc1", :view, "user:alice", opts)
      refute Adapter.check?("document:doc1", :view, "user:bob", opts)
      refute Adapter.check?("invalid_object", :view, "user:alice", opts)

      assert Adapter.lookup_resources!("document", :view, "user:alice", opts) == ["doc1"]

      assert_raise Error, fn ->
        Adapter.lookup_resources!("document", :view, "invalid_subject", opts)
      end

      assert_raise Error, ~r/Invalid adapter/, fn ->
        Adapter.resolve_adapter(adapter: "not_an_atom")
      end
    end
  end

  describe "AshAuthzed.Adapters.Memory contract & async isolation" do
    test "handles duplicate writes (idempotency), non-existent deletes, wildcards, and indirect group#member traversal" do
      store = :"memory_contract_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: store, schema: @schema_zed})
      opts = [store: store]

      # 1. Idempotent duplicate writes (:create and :touch)
      assert {:ok, :synced} =
               Memory.write_tuples(
                 [
                   {:create, "document:doc1#owner@user:alice"},
                   {:create, "document:doc1#owner@user:alice"},
                   {:touch, "document:doc1#owner@user:alice"}
                 ],
                 opts
               )

      assert Memory.list_tuples(store) == ["document:doc1#owner@user:alice"]

      # 2. Deleting a non-existent tuple succeeds idempotently
      assert {:ok, :synced} =
               Memory.write_tuples([{:delete, "document:doc999#owner@user:nobody"}], opts)

      # 3. Subject-set / indirect relationship traversal (`group:eng#member`)
      assert {:ok, :synced} =
               Memory.write_tuples(
                 [
                   {:create, "group:eng#member@user:bob"},
                   {:create, "document:doc2#viewer@group:eng#member"}
                 ],
                 opts
               )

      assert {:ok, true} = Memory.check("document:doc2", "view", "user:bob", opts)
      assert {:ok, false} = Memory.check("document:doc2", "edit", "user:bob", opts)
      assert {:ok, ["doc2"]} = Memory.lookup_resources("document", "view", "user:bob", opts)

      # 4. Wildcard tuples (`user:*`) and deleting wildcard tuples
      assert {:ok, :synced} =
               Memory.write_tuples([{:create, "document:public_doc#viewer@user:*"}], opts)

      assert {:ok, true} = Memory.check("document:public_doc", "view", "user:stranger", opts)

      assert {:ok, :synced} =
               Memory.write_tuples([{:delete, "document:public_doc#viewer@user:*"}], opts)

      assert {:ok, false} = Memory.check("document:public_doc", "view", "user:stranger", opts)
    end

    test "isolates state across concurrent supervised Memory stores without cross-test pollution" do
      store_a = :"isolated_store_a_#{System.unique_integer([:positive])}"
      store_b = :"isolated_store_b_#{System.unique_integer([:positive])}"

      start_supervised!({Memory, name: store_a, schema: @schema_zed}, id: store_a)
      start_supervised!({Memory, name: store_b, schema: @schema_zed}, id: store_b)

      assert {:ok, :synced} =
               Memory.write_tuples([{:create, "document:secret_a#owner@user:alice"}],
                 store: store_a
               )

      assert {:ok, :synced} =
               Memory.write_tuples([{:create, "document:secret_b#owner@user:bob"}],
                 store: store_b
               )

      assert {:ok, ["secret_a"]} =
               Memory.lookup_resources("document", "view", "user:alice", store: store_a)

      assert {:ok, []} =
               Memory.lookup_resources("document", "view", "user:alice", store: store_b)

      assert {:ok, ["secret_b"]} =
               Memory.lookup_resources("document", "view", "user:bob", store: store_b)

      assert {:ok, []} =
               Memory.lookup_resources("document", "view", "user:bob", store: store_a)
    end

    test "validates startup options, schema file loading, and error states" do
      # Unstarted store returns :not_started
      assert {:error, %Error{reason: :not_started}} =
               Memory.check("document:1", "view", "user:alice", store: :non_existent_store)

      assert {:error, %Error{reason: :not_started}} =
               Memory.write_tuples([{:create, "document:1#owner@user:alice"}],
                 store: :non_existent_store
               )

      # Invalid NimbleOptions
      assert {:error, %Error{reason: :invalid_options}} = Memory.start_link([])

      # Missing schema file
      assert {:error, %Error{reason: :schema_file_error}} =
               Memory.start_link(
                 name: :"err_file_#{System.unique_integer([:positive])}",
                 schema: {:file, "non_existent_schema.zed"}
               )

      # Invalid .zed syntax
      assert {:error, %Error{reason: :invalid_schema}} =
               Memory.start_link(
                 name: :"err_syntax_#{System.unique_integer([:positive])}",
                 schema: "not valid zed syntax {{{"
               )

      # Invalid initial relationships
      assert {:error, %Error{reason: :invalid_relationship}} =
               Memory.start_link(
                 name: :"err_rel_#{System.unique_integer([:positive])}",
                 schema: @schema_zed,
                 relationships: ["malformed_tuple"]
               )
    end
  end

  describe "AshAuthzed.Adapters.Licet unit tests" do
    test "returns {:error, %Error{reason: :missing_instance}} when :instance option is missing" do
      assert {:error, %Error{reason: :missing_instance}} =
               LicetAdapter.check("document:1", "view", "user:alice", [])

      assert {:error, %Error{reason: :missing_instance}} =
               LicetAdapter.lookup_resources("document", "view", "user:alice", [])

      assert {:error, %Error{reason: :missing_instance}} =
               LicetAdapter.write_tuples([{:create, "document:1#owner@user:alice"}], [])

      assert {:ok, :noop} = LicetAdapter.write_tuples([], [])
    end
  end

  describe "Licet YAML parsing & validation (priv/licet/user_permissions.yaml)" do
    test "evaluates valid permissions, catches missing permission keys, and handles malformed YAML" do
      yaml_content = File.read!("priv/licet/user_permissions.yaml")
      assert {:ok, parsed} = Licet.Validate.parse(yaml_content)
      assert is_map(parsed.schema)
      assert parsed.relationships != []

      # Unknown permission evaluation returns error on explain/check
      assert {:error, _reason} =
               Licet.Validate.explain(
                 yaml_content,
                 "user_profile:alice#non_existent_perm@user:alice"
               )

      # Malformed YAML returns parse error
      assert {:error, _reason} = Licet.Validate.parse("::: invalid: yaml: [unclosed")
    end
  end

  describe "capability role contract parity across Memory, SpiceDBHttp, and Licet" do
    test "Memory and SpiceDBHttp evaluate capability permissions (admin_create, admin_edit, admin_delete) identically" do
      {:ok, parsed} = Licet.Validate.parse(File.read!("priv/licet/admin_capabilities.yaml"))
      store = :"cap_contract_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: store, schema: parsed.schema})

      tuples = [
        {:create, "catalog:main#admin@user:alice"},
        {:create, "catalog:main#can_edit@user:bob"},
        {:create, "managed_item:spec_1#catalog@catalog:main"}
      ]

      mem_opts = [adapter: :memory, adapter_opts: [store: store]]
      assert {:ok, :synced} = Adapter.write_tuples(tuples, mem_opts)

      # Bridge SpiceDBHttp plug directly to our Memory store to verify wire-protocol + contract parity
      spicedb_plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw_body)

        case conn.request_path do
          "/v1/permissions/check" ->
            res = "#{body["resource"]["objectType"]}:#{body["resource"]["objectId"]}"
            perm = body["permission"]

            sub =
              "#{body["subject"]["object"]["objectType"]}:#{body["subject"]["object"]["objectId"]}"

            {:ok, allowed?} = Memory.check(res, perm, sub, store: store)

            permissionship =
              if allowed?,
                do: "PERMISSIONSHIP_HAS_PERMISSION",
                else: "PERMISSIONSHIP_NO_PERMISSION"

            Req.Test.json(conn, %{"permissionship" => permissionship})

          "/v1/permissions/resources" ->
            res_type = body["resourceObjectType"]
            perm = body["permission"]

            sub =
              "#{body["subject"]["object"]["objectType"]}:#{body["subject"]["object"]["objectId"]}"

            {:ok, ids} = Memory.lookup_resources(res_type, perm, sub, store: store)

            results = Enum.map(ids, &%{"result" => %{"resourceObjectId" => &1}})
            Req.Test.json(conn, %{"results" => results})
        end
      end

      http_opts = [
        adapter: :spicedb_http,
        adapter_opts: [req_options: [plug: spicedb_plug]]
      ]

      for opts <- [mem_opts, http_opts] do
        # Full admin (alice) has all 3 capabilities
        assert Adapter.check?("catalog:main", :admin_create, "user:alice", opts)
        assert Adapter.check?("managed_item:spec_1", :admin_edit, "user:alice", opts)
        assert Adapter.check?("managed_item:spec_1", :admin_delete, "user:alice", opts)

        assert Adapter.lookup_resources!("managed_item", :admin_edit, "user:alice", opts) == [
                 "spec_1"
               ]

        # Scoped editor (bob) has admin_edit, but NOT admin_create or admin_delete
        refute Adapter.check?("catalog:main", :admin_create, "user:bob", opts)
        assert Adapter.check?("managed_item:spec_1", :admin_edit, "user:bob", opts)
        refute Adapter.check?("managed_item:spec_1", :admin_delete, "user:bob", opts)

        assert Adapter.lookup_resources!("managed_item", :admin_edit, "user:bob", opts) == [
                 "spec_1"
               ]

        assert Adapter.lookup_resources!("managed_item", :admin_delete, "user:bob", opts) == []
      end
    end
  end
end
