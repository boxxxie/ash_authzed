defmodule AshAuthzed.SchemaValidationTest do
  use ExUnit.Case, async: true

  @user_validation_file "priv/licet/user_permissions.yaml"
  @capability_validation_file "priv/licet/admin_capabilities.yaml"

  test "user and admin permission matrix passes all Licet.Validate assertions" do
    assert :ok = Licet.Validate.run_file(@user_validation_file)
  end

  test "admin capability permission matrix passes all Licet.Validate assertions" do
    assert :ok = Licet.Validate.run_file(@capability_validation_file)
  end

  test "Licet.Validate.explain traces why an admin cannot edit another admin" do
    yaml_source = File.read!(@user_validation_file)

    assert {:ok, :denied, trace} =
             Licet.Validate.explain(yaml_source, "user_profile:bob#edit@user:alice")

    assert trace.resource == "user_profile:bob"
    assert trace.permission == "edit"
    assert trace.result == :denied
  end

  test "AuthZed CLI (`zed validate`) validates both schemas and assertions with zero warnings" do
    case System.find_executable("zed") do
      nil ->
        :ok

      zed_bin ->
        {output, exit_code} =
          System.cmd(
            zed_bin,
            ["validate", @user_validation_file, @capability_validation_file],
            stderr_to_stdout: true
          )

        assert exit_code == 0, "Expected `zed validate` to exit 0, got:\n#{output}"
        assert output =~ "Success! - 18 relationships loaded, 25 assertions run"
        assert output =~ "Success! - 5 relationships loaded, 15 assertions run"
        refute output =~ "warning:"
    end
  end
end
