defmodule Mix.Tasks.AshAuthzed.Install.Docs do
  @moduledoc false

  def short_doc do
    "Installs and configures AshAuthzed in an Ash project."
  end

  def example do
    "mix igniter.install ash_authzed --adapter licet"
  end

  def long_doc do
    """
    #{short_doc()}

    ## Options

    * `--adapter` or `-a` — Authorization backend to configure (`licet` or `spicedb`). Defaults to `licet`.
    * `--repo` or `-r` — The Ecto repo for Licet to use. Defaults to `<MyApp>.Repo`.
    * `--schema-path` — Path to the `.zed` or `.yaml` schema bundle. Defaults to `"priv/licet/user_permissions.yaml"`.

    ## Example

    ```bash
    #{example()}
    ```
    """
  end
end

if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.AshAuthzed.Install do
    @shortdoc Mix.Tasks.AshAuthzed.Install.Docs.short_doc()
    @moduledoc Mix.Tasks.AshAuthzed.Install.Docs.long_doc()

    use Igniter.Mix.Task

    alias AshAuthzed.Adapters.Licet, as: LicetAdapter
    alias AshAuthzed.Adapters.SpiceDBHttp
    alias Igniter.Code.Common
    alias Igniter.Mix.Task.Info
    alias Igniter.Project.Application, as: IgniterApp
    alias Igniter.Project.Config, as: IgniterConfig
    alias Igniter.Project.Formatter
    alias Igniter.Project.Module, as: IgniterModule
    alias Mix.Tasks.AshAuthzed.Install.Docs

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Info{
        group: :ash,
        example: Docs.example(),
        schema: [
          adapter: :string,
          repo: :string,
          schema_path: :string
        ],
        aliases: [
          a: :adapter,
          r: :repo
        ],
        defaults: [
          adapter: "licet",
          schema_path: "priv/licet/user_permissions.yaml"
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      otp_app = IgniterApp.app_name(igniter)
      app_prefix = IgniterModule.module_name_prefix(igniter)
      opts = igniter.args.options

      adapter_opt = String.downcase(opts[:adapter] || "licet")
      schema_path = opts[:schema_path] || "priv/licet/user_permissions.yaml"

      repo_module =
        case opts[:repo] do
          nil -> Module.concat([app_prefix, Repo])
          custom -> IgniterModule.parse(custom)
        end

      licet_module = Module.concat([app_prefix, Licet])

      igniter
      |> Formatter.import_dep(:ash_authzed)
      |> create_starter_schema_file(schema_path)
      |> configure_backend(adapter_opt, otp_app, licet_module, repo_module, schema_path)
    end

    @doc """
    Patches an existing Ash Resource module to use `Ash.Policy.Authorizer` and `AshAuthzed`,
    and appends a starter `authzed do ... end` block.
    """
    @spec add_authzed_to_resource(Igniter.t(), module(), String.t()) :: Igniter.t()
    def add_authzed_to_resource(igniter, resource_module, object_type) do
      igniter
      |> Spark.Igniter.add_extension(
        resource_module,
        Ash.Resource,
        :authorizers,
        Ash.Policy.Authorizer
      )
      |> Spark.Igniter.add_extension(
        resource_module,
        Ash.Resource,
        :extensions,
        AshAuthzed
      )
      |> IgniterModule.find_and_update_module!(resource_module, fn zipper ->
        {:ok,
         Common.add_code(zipper, """
         authzed do
           object_type #{inspect(object_type)}
           relation :owner, subject_type: "user", subject_id: :id
         end
         """)}
      end)
    end

    # --- Step 1: Scaffold Starter `.zed` / YAML Validation Bundle ---

    defp create_starter_schema_file(igniter, schema_path) do
      Igniter.create_new_file(
        igniter,
        schema_path,
        starter_yaml_template(),
        on_exists: :skip
      )
    end

    # --- Step 2: Configure Adapter, Application Tree & Config Files ---

    defp configure_backend(
           igniter,
           "spicedb",
           _otp_app,
           _licet_module,
           _repo_module,
           schema_path
         ) do
      igniter
      |> IgniterConfig.configure(
        "config.exs",
        :ash_authzed,
        [:adapter],
        SpiceDBHttp
      )
      |> IgniterConfig.configure(
        "config.exs",
        :ash_authzed,
        [:schema_path],
        schema_path
      )
      |> IgniterConfig.configure(
        "config.exs",
        :ash_authzed,
        [:spicedb_url],
        "http://localhost:8443"
      )
      |> IgniterConfig.configure(
        "test.exs",
        :ash_authzed,
        [:consistency],
        :full
      )
    end

    defp configure_backend(igniter, _licet, otp_app, licet_module, repo_module, schema_path) do
      igniter
      |> create_licet_module(licet_module, otp_app, repo_module, schema_path)
      |> IgniterApp.add_new_child(licet_module, after: [repo_module])
      |> IgniterConfig.configure(
        "config.exs",
        :ash_authzed,
        [:adapter],
        LicetAdapter
      )
      |> IgniterConfig.configure(
        "config.exs",
        :ash_authzed,
        [:licet_instance],
        licet_module
      )
      |> IgniterConfig.configure(
        "config.exs",
        :ash_authzed,
        [:schema_path],
        schema_path
      )
      |> IgniterConfig.configure(
        "config.exs",
        :ash_authzed,
        [:consistency],
        :minimize_latency
      )
      |> IgniterConfig.configure(
        "test.exs",
        :ash_authzed,
        [:consistency],
        :full
      )
      |> Igniter.add_notice("""
      AshAuthzed has been configured with `#{inspect(licet_module)}`!

      Next steps:
      1. Ensure your Licet database migration is generated and applied:
         mix ecto.gen.migration add_licet_tables
         (Inside the migration, call `Licet.Migrations.up()` / `Licet.Migrations.down()`)
      2. Validate your permission matrix at any time:
         mix test
      """)
    end

    defp create_licet_module(igniter, licet_module, otp_app, repo_module, schema_path) do
      IgniterModule.create_module(
        igniter,
        licet_module,
        """
        @moduledoc \"\"\"
        Embedded Zanzibar / SpiceDB authorization engine powered by Licet and #{inspect(repo_module)}.
        \"\"\"
        use Licet,
          otp_app: #{inspect(otp_app)},
          repo: #{inspect(repo_module)},
          schema_file: #{inspect(schema_path)}
        """
      )
    end

    defp starter_yaml_template do
      """
      ---
      schema: |
        definition user {}

        definition platform {
          relation super_admin: user
          relation admin: user
          relation member: user

          permission assign_member      = super_admin + admin
          permission assign_admin       = super_admin
          permission assign_super_admin = super_admin
        }

        definition user_profile {
          relation owner: user
          relation platform: platform
          relation is_protected_admin: user:*

          permission view        = owner + platform->admin + platform->super_admin
          permission edit        = owner + platform->super_admin + (platform->admin - is_protected_admin)
          permission delete      = (platform->super_admin - owner) + (platform->admin - is_protected_admin - owner)
          permission change_role = (platform->super_admin - owner) + (platform->admin - is_protected_admin - owner)
        }

      relationships: |
        platform:main#super_admin@user:root
        platform:main#admin@user:alice
        platform:main#admin@user:bob
        platform:main#member@user:charlie

        user_profile:root#owner@user:root
        user_profile:root#platform@platform:main
        user_profile:root#is_protected_admin@user:*

        user_profile:alice#owner@user:alice
        user_profile:alice#platform@platform:main
        user_profile:alice#is_protected_admin@user:*

        user_profile:bob#owner@user:bob
        user_profile:bob#platform@platform:main
        user_profile:bob#is_protected_admin@user:*

        user_profile:charlie#owner@user:charlie
        user_profile:charlie#platform@platform:main

      assertions:
        assertTrue:
          - "user_profile:alice#edit@user:alice"
          - "user_profile:charlie#edit@user:alice"
          - "user_profile:alice#edit@user:root"
          - "platform:main#assign_member@user:alice"
          - "platform:main#assign_admin@user:root"
        assertFalse:
          - "user_profile:bob#edit@user:alice"
          - "user_profile:root#edit@user:alice"
          - "platform:main#assign_admin@user:alice"
          - "user_profile:alice#delete@user:alice"
      """
    end
  end
else
  defmodule Mix.Tasks.AshAuthzed.Install do
    @shortdoc "#{Mix.Tasks.AshAuthzed.Install.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc Mix.Tasks.AshAuthzed.Install.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_authzed.install' requires `igniter`.
      Please add `{:igniter, "~> 0.6", only: [:dev, :test]}` to your `mix.exs` dependencies and try again.
      """)

      exit({:shutdown, 1})
    end
  end
end
