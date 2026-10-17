defmodule AshAuthzed.Adapters.SpiceDBHttpTest do
  use ExUnit.Case, async: true

  alias AshAuthzed.Adapters.SpiceDBHttp

  test "parse_tuple_to_json/1 parses standard and wildcard tuples" do
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
end
