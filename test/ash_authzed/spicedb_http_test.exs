defmodule AshAuthzed.Adapters.SpiceDBHttpTest do
  use ExUnit.Case, async: true

  alias AshAuthzed.Adapters.SpiceDBHttp
  alias AshAuthzed.Error

  describe "parse_tuple_to_json/1" do
    test "parses standard, wildcard, and subject-relation tuples" do
      assert {:ok,
              %{
                resource: %{objectType: "user_profile", objectId: "bob"},
                relation: "is_protected_admin",
                subject: %{object: %{objectType: "user", objectId: "*"}}
              }} = SpiceDBHttp.parse_tuple_to_json("user_profile:bob#is_protected_admin@user:*")

      assert {:ok,
              %{
                resource: %{objectType: "document", objectId: "doc1"},
                relation: "viewer",
                subject: %{
                  object: %{objectType: "team", objectId: "eng"},
                  optionalRelation: "member"
                }
              }} = SpiceDBHttp.parse_tuple_to_json("document:doc1#viewer@team:eng#member")
    end

    test "returns %AshAuthzed.Error{reason: :invalid_tuple} on malformed tuple string" do
      assert {:error, %Error{reason: :invalid_tuple}} =
               SpiceDBHttp.parse_tuple_to_json("not_a_valid_tuple")
    end
  end

  describe "check/4 endpoint, headers, consistency, and responses" do
    test "sends expected payload and Authorization header forPERMISSIONSHIP_HAS_PERMISSION" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/permissions/check"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_psk_123"]

        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(raw_body)

        assert decoded == %{
                 "resource" => %{"objectType" => "user_profile", "objectId" => "alice"},
                 "permission" => "edit",
                 "subject" => %{"object" => %{"objectType" => "user", "objectId" => "root"}}
               }

        Req.Test.json(conn, %{"permissionship" => "PERMISSIONSHIP_HAS_PERMISSION"})
      end

      assert {:ok, true} =
               SpiceDBHttp.check("user_profile:alice", :edit, "user:root",
                 url: "http://spicedb.local:8443/",
                 token: "test_psk_123",
                 req_options: [plug: plug]
               )
    end

    test "returns {:ok, false} when permissionship is PERMISSIONSHIP_NO_PERMISSION" do
      plug = fn conn ->
        Req.Test.json(conn, %{"permissionship" => "PERMISSIONSHIP_NO_PERMISSION"})
      end

      assert {:ok, false} =
               SpiceDBHttp.check("user_profile:bob", "edit", "user:alice#member",
                 req_options: [plug: plug]
               )
    end

    test "supports consistency modes (fully_consistent, minimize_latency, at_least_as_fresh)" do
      for {mode, expected_consistency} <- [
            {:fully_consistent, %{"fullyConsistent" => true}},
            {:full, %{"fullyConsistent" => true}},
            {:minimize_latency, %{"minimizeLatency" => true}},
            {{:at_least_as_fresh, "zed_tok_99"},
             %{"atLeastAsFresh" => %{"token" => "zed_tok_99"}}},
            {{:at_exact_snapshot, "zed_snap_1"},
             %{"atExactSnapshot" => %{"token" => "zed_snap_1"}}}
          ] do
        plug = fn conn ->
          {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(raw_body)
          assert decoded["consistency"] == expected_consistency
          Req.Test.json(conn, %{"permissionship" => "PERMISSIONSHIP_HAS_PERMISSION"})
        end

        assert {:ok, true} =
                 SpiceDBHttp.check("user_profile:alice", "view", "user:alice",
                   consistency: mode,
                   req_options: [plug: plug]
                 )
      end
    end

    test "returns {:error, %AshAuthzed.Error{}} on unexpected response or invalid object/subject" do
      plug = fn conn ->
        Req.Test.json(conn, %{"unexpected" => "payload"})
      end

      assert {:error, %Error{reason: :unexpected_spicedb_response}} =
               SpiceDBHttp.check("user_profile:alice", "view", "user:alice",
                 req_options: [plug: plug]
               )

      assert {:error, %Error{reason: :invalid_object}} =
               SpiceDBHttp.check("invalid_resource", "view", "user:alice", [])

      assert {:error, %Error{reason: :invalid_object}} =
               SpiceDBHttp.check("user_profile:alice", "view", "invalid_subject", [])
    end
  end

  describe "lookup_resources/4" do
    test "parses results array, single result map, and NDJSON streaming responses" do
      # 1. Results list format
      plug_list = fn conn ->
        assert conn.request_path == "/v1/permissions/resources"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(raw_body)

        assert decoded == %{
                 "resourceObjectType" => "user_profile",
                 "permission" => "view",
                 "subject" => %{"object" => %{"objectType" => "user", "objectId" => "alice"}},
                 "consistency" => %{"fullyConsistent" => true}
               }

        Req.Test.json(conn, %{
          "results" => [
            %{"result" => %{"resourceObjectId" => "alice"}},
            %{"resourceObjectId" => "charlie"}
          ]
        })
      end

      assert {:ok, ["alice", "charlie"]} =
               SpiceDBHttp.lookup_resources("user_profile", :view, "user:alice",
                 consistency: :fully_consistent,
                 req_options: [plug: plug_list]
               )

      # 2. NDJSON newline-delimited stream format (both x-ndjson and application/json from grpc-gateway)
      for content_type <- ["application/x-ndjson", "application/json"] do
        plug_ndjson = fn conn ->
          ndjson =
            ~s({"result":{"resourceObjectId":"doc_1"}}\n{"result":{"resourceObjectId":"doc_2"}}\n)

          conn
          |> Plug.Conn.put_resp_content_type(content_type)
          |> Plug.Conn.send_resp(200, ndjson)
        end

        assert {:ok, ["doc_1", "doc_2"]} =
                 SpiceDBHttp.lookup_resources("document", "view", "user:alice",
                   req_options: [plug: plug_ndjson]
                 )
      end

      # 3. Single result object `{"result": {"resourceObjectId": "doc_single"}}` with application/json
      plug_single = fn conn ->
        Req.Test.json(conn, %{"result" => %{"resourceObjectId" => "doc_single"}})
      end

      assert {:ok, ["doc_single"]} =
               SpiceDBHttp.lookup_resources("document", "view", "user:alice",
                 req_options: [plug: plug_single]
               )
    end
  end

  describe "write_tuples/2" do
    test "short-circuits empty operations list with {:ok, :noop}" do
      assert {:ok, :noop} = SpiceDBHttp.write_tuples([], [])
    end

    test "formats OPERATION_TOUCH and OPERATION_DELETE updates and extracts writtenAt token" do
      plug = fn conn ->
        assert conn.request_path == "/v1/relationships/write"
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(raw_body)

        assert %{
                 "updates" => [
                   %{
                     "operation" => "OPERATION_TOUCH",
                     "relationship" => %{
                       "resource" => %{"objectType" => "user_profile", "objectId" => "alice"},
                       "relation" => "owner",
                       "subject" => %{
                         "object" => %{"objectType" => "user", "objectId" => "alice"}
                       }
                     }
                   },
                   %{
                     "operation" => "OPERATION_TOUCH",
                     "relationship" => %{
                       "resource" => %{"objectType" => "platform", "objectId" => "main"},
                       "relation" => "admin",
                       "subject" => %{
                         "object" => %{"objectType" => "user", "objectId" => "alice"}
                       }
                     }
                   },
                   %{
                     "operation" => "OPERATION_DELETE",
                     "relationship" => %{
                       "resource" => %{"objectType" => "platform", "objectId" => "main"},
                       "relation" => "member",
                       "subject" => %{
                         "object" => %{"objectType" => "user", "objectId" => "alice"}
                       }
                     }
                   }
                 ]
               } = decoded

        Req.Test.json(conn, %{"writtenAt" => %{"token" => "zed_token_abc123"}})
      end

      ops = [
        {:create, "user_profile:alice#owner@user:alice"},
        {:touch, "platform:main#admin@user:alice"},
        {:delete, "platform:main#member@user:alice"}
      ]

      assert {:ok, "zed_token_abc123"} =
               SpiceDBHttp.write_tuples(ops, req_options: [plug: plug])
    end

    test "returns {:error, %AshAuthzed.Error{reason: :invalid_tuple}} when an operation tuple is invalid" do
      assert {:error, %Error{reason: :invalid_tuple}} =
               SpiceDBHttp.write_tuples([{:create, "bad_tuple"}], [])
    end
  end

  describe "HTTP error & network failure mapping" do
    for status <- [401, 403, 422, 500] do
      test "maps HTTP #{status} response to {:error, %AshAuthzed.Error{reason: :spicedb_http_error}}" do
        plug = fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            unquote(status),
            Jason.encode!(%{"code" => unquote(status), "message" => "failure"})
          )
        end

        assert {:error,
                %Error{
                  reason: :spicedb_http_error,
                  details: %{status: unquote(status), body: %{"message" => "failure"}}
                }} =
                 SpiceDBHttp.check("user_profile:alice", "view", "user:alice",
                   req_options: [plug: plug, retry: false]
                 )
      end
    end

    test "maps transport / timeout exceptions to {:error, %AshAuthzed.Error{reason: :spicedb_request_failed}}" do
      plug = fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end

      assert {:error,
              %Error{
                reason: :spicedb_request_failed,
                details: %Req.TransportError{reason: :timeout}
              }} =
               SpiceDBHttp.lookup_resources("user_profile", "view", "user:alice",
                 req_options: [plug: plug, retry: false]
               )
    end
  end
end
