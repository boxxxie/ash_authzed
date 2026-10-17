defmodule AshAuthzed.SchemaValidationTest do
  use ExUnit.Case, async: true

  @validation_file "priv/licet/user_permissions.yaml"

  test "user and admin permission matrix passes all Licet.Validate assertions" do
    assert :ok = Licet.Validate.run_file(@validation_file)
  end

  test "Licet.Validate.explain traces why an admin cannot edit another admin" do
    yaml_source = File.read!(@validation_file)

    assert {:ok, :denied, trace} =
             Licet.Validate.explain(yaml_source, "user_profile:bob#edit@user:alice")

    assert trace.resource == "user_profile:bob"
    assert trace.permission == "edit"
    assert trace.result == :denied
  end
end
