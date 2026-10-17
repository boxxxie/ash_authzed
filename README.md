# AshAuthzed

Declarative Zanzibar / Relationship-Based Access Control (ReBAC) extension for [Ash Framework](https://hexdocs.pm/ash) backed by:

- **[`Licet`](https://hex.pm/packages/licet)**: Embedded Zanzibar engine in Elixir backed by your existing `Ecto.Repo` (Postgres) with native transaction & SQL Sandbox support, plus zero-DB YAML validation (`Licet.Validate`).
- **SpiceDB / Authzed HTTP (`Req`)**: External SpiceDB / Authzed server via `/v1/permissions/*` and `/v1/relationships/write`.
- **`AshAuthzed.Adapters.Memory`**: In-memory `Licet.Engine` store for sub-millisecond, zero-DB `ExUnit` tests.

## Quick Start

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  authzed do
    object_type "user_profile"
    adapter :licet
    adapter_opts instance: MyApp.Licet

    # Writes: user_profile:<id>#owner@user:<id>
    relation :owner, subject_type: "user", subject_id: :id

    # Writes: user_profile:<id>#platform@platform:main
    relation :platform, static_subject: "platform:main"

    # Writes: platform:main#<role>@user:<id> (and deletes old role tuple on update!)
    external_role :role,
      target: "platform:main",
      subject_type: "user",
      subject_id: :id,
      role_mapping: %{user: "member", admin: "admin", super_admin: "super_admin"}

    # Writes wildcard tag: user_profile:<id>#is_protected_admin@user:* when role in [:admin, :super_admin]
    conditional_wildcard :is_protected_admin,
      subject_type: "user",
      attribute: :role,
      in: [:admin, :super_admin]
  end

  policies do
    policy action(:read) do
      authorize_if rebac_can(:view)
    end

    policy action(:update_profile) do
      authorize_if rebac_can(:edit)
    end

    policy action(:destroy) do
      authorize_if rebac_can(:delete)
    end

    policy action(:change_role) do
      forbid_unless rebac_can_assign(:role, on: "platform:main")
      authorize_if rebac_can(:change_role)
    end
  end
end
```
