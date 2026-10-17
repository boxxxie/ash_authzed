defmodule Mix.Tasks.AshAuthzed.InstallTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  alias Mix.Tasks.AshAuthzed.Install

  @default_files %{
    "config/config.exs" => """
    import Config
    """,
    "config/test.exs" => """
    import Config
    """
  }

  test "installs with default Licet adapter, creates MyApp.Licet, and configures config.exs" do
    test_project(files: @default_files)
    |> Igniter.compose_task("ash_authzed.install", [])
    |> assert_creates("priv/licet/user_permissions.yaml")
    |> assert_creates("lib/test/licet.ex", """
    defmodule Test.Licet do
      @moduledoc \"\"\"
      Embedded Zanzibar / SpiceDB authorization engine powered by Licet and Test.Repo.
      \"\"\"
      use Licet,
        otp_app: :test,
        repo: Test.Repo,
        schema_file: "priv/licet/user_permissions.yaml"
    end
    """)
    |> assert_has_patch("config/config.exs", """
    + |config :ash_authzed,
    + |  adapter: AshAuthzed.Adapters.Licet,
    + |  licet_instance: Test.Licet,
    + |  schema_path: "priv/licet/user_permissions.yaml",
    + |  consistency: :minimize_latency
    """)
    |> assert_has_patch("config/test.exs", """
    + |config :ash_authzed, consistency: :full
    """)
  end

  test "installs with --adapter spicedb and skips generating a local Licet module" do
    test_project(files: @default_files)
    |> Igniter.compose_task("ash_authzed.install", ["--adapter", "spicedb"])
    |> assert_creates("priv/licet/user_permissions.yaml")
    |> refute_creates("lib/test/licet.ex")
    |> assert_has_patch("config/config.exs", """
    + |config :ash_authzed,
    + |  adapter: AshAuthzed.Adapters.SpiceDBHttp,
    + |  schema_path: "priv/licet/user_permissions.yaml",
    + |  spicedb_url: "http://localhost:8443"
    """)
    |> assert_has_patch("config/test.exs", """
    + |config :ash_authzed, consistency: :full
    """)
  end

  test "add_authzed_to_resource/3 adds Ash.Policy.Authorizer, AshAuthzed, and authzed block" do
    files =
      Map.put(@default_files, "lib/test/accounts/user.ex", """
      defmodule Test.Accounts.User do
        use Ash.Resource,
          domain: Test.Accounts

        attributes do
          uuid_primary_key :id
        end
      end
      """)

    test_project(files: files)
    |> Install.add_authzed_to_resource(
      Module.concat(["Test", "Accounts", "User"]),
      "user_profile"
    )
    |> assert_has_patch("lib/test/accounts/user.ex", """
    + |    authorizers: [Ash.Policy.Authorizer],
    + |    extensions: [AshAuthzed]
    """)
    |> assert_has_patch("lib/test/accounts/user.ex", """
    + |  authzed do
    + |    object_type("user_profile")
    + |    relation(:owner, subject_type: "user", subject_id: :id)
    + |  end
    """)
  end
end
