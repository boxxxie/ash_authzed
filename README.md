# AshAuthzed

[![CI](https://github.com/boxxxie/ash_authzed/actions/workflows/elixir.yml/badge.svg)](https://github.com/boxxxie/ash_authzed/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ash_authzed.svg)](https://hex.pm/packages/ash_authzed)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ash_authzed)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/ash_authzed.svg?color=brightgreen)](https://hex.pm/packages/ash_authzed)
[![License](https://img.shields.io/github/license/boxxxie/ash_authzed.svg)](https://github.com/boxxxie/ash_authzed/blob/master/LICENSE)

**Declarative Relationship-Based Access Control (ReBAC) and Zanzibar-style permissions for the [Ash Framework](https://ash-hq.org/).**

`AshAuthzed` extends `Ash.Resource` with a Spark DSL that bridges [`Ash.Policy.Authorizer`](https://hexdocs.pm/ash/Ash.Policy.Authorizer.html) and resource lifecycle hooks with [AuthZed / SpiceDB](https://authzed.com/) or [`Licet`](https://hex.pm/packages/licet) (an embedded Elixir/Postgres Zanzibar engine). Define your resource relationships once, verify them against your `.zed` or `.yaml` schema at compile time, and let `AshAuthzed` automatically keep your permission tuples in sync across single and bulk actions.

---

## Quick Look

```elixir
defmodule MyApp.Workspace.Document do
  use Ash.Resource,
    domain: MyApp.Workspace,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  authzed do
    object_type "document"
    schema_path "priv/authzed/schema.zed"

    relation :organization, subject_type: "organization", subject_id: :organization_id
    relation :owner, subject_type: "user", subject_id: :owner_id
    external_role :role, target: "organization:main", subject_type: "user", subject_id: :owner_id
  end

  policies do
    # Filters collection reads via lookup_resources & guards actions via check_permission
    policy action_type(:read) do
      authorize_if authzed_can(:view)
    end

    policy action(:update) do
      authorize_if authzed_can(:edit)
    end
  end
end
```

---

## Key Features

- **Declarative & Schema-First Resource DSL** — Map Zanzibar `object_type`, direct `relation` tuples, `external_role` mappings, and `conditional_wildcard` rules inside your `Ash.Resource` definitions (`authzed` / `rebac` DSL sections)—or set `from_zed: true` and `derive_policies: true` to automatically derive relations and policies directly from your `.zed` schema.
- **Compile-Time Schema Verification** — Validates your resource's `object_type`, relations, enum role mappings, and policy check permissions against your `.zed` or `.yaml` schema at compile time—complete with *"Did you mean?"* Jaro-distance suggestions and automatic `@external_resource` recompilation when your schema file changes.
- **Native Ash Policy Checks** — Use `authzed_can/1,2` and `authzed_can_assign/2` (or their `rebac_*` aliases) inside `policies` blocks to filter collection reads via `lookup_resources` and authorize mutations or role assignments via `check?`.
- **Automatic & Batched Tuple Synchronization** — Automatically wires lifecycle hooks onto `:create`, `:update`, and `:destroy` actions. Supports single-record mutations, atomic updates, and deduplicated batch writes across `Ash.bulk_create!`, `Ash.bulk_update!`, and `Ash.bulk_destroy!`.
- **Built-In Mix Tasks** — Includes `mix ash_authzed.install` (Igniter installer), `mix ash_authzed.schema.apply` (runtime `.zed` / `.yaml` schema deployment across adapters), `mix ash_authzed.backfill` (keyset-paginated tuple reconciliation for existing records), and `mix ash_authzed.bench` (cross-adapter throughput benchmarking).

## Pluggable Adapters

Choose the backing engine that fits your environment without changing a line of resource or policy code:

| Adapter | Option | Backing Store | Best For |
| :--- | :--- | :--- | :--- |
| `AshAuthzed.Adapters.Licet` | `:licet` | Existing `Ecto.Repo` (Postgres) | Zero-infrastructure setups needing native Ecto SQL Sandbox & transaction support |
| `AshAuthzed.Adapters.SpiceDBHttp` | `:spicedb_http` | SpiceDB / AuthZed HTTP API (`Req`) | Multi-service or high-scale production clusters (`/v1/permissions/*`, `/v1/relationships/write`) |
| `AshAuthzed.Adapters.Memory` | `:memory` | Caller-supervised in-memory `Licet` | Sub-millisecond, zero-DB `async: true` ExUnit tests |

---

## Installation

### Using Igniter (Recommended)

If your project uses [Igniter](https://hexdocs.pm/igniter), install and configure `ash_authzed` automatically:

```bash
# Default (embedded Licet + Ecto Repo)
mix igniter.install ash_authzed --yes

# Or configure for an external SpiceDB HTTP server
mix igniter.install ash_authzed --adapter spicedb --yes
```

### Manual Installation

1. Add `:ash_authzed` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_authzed, "~> 0.2.0"},
    # Required only if using AshAuthzed.Adapters.SpiceDBHttp:
    {:req, "~> 0.5"}
  ]
end
```

2. Add `:ash_authzed` to your `.formatter.exs` so `mix format` preserves DSL syntax without parentheses:

```elixir
[
  import_deps: [:ash, :ash_authzed],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

---

## Configuration

`AshAuthzed` uses a behaviour-driven adapter interface (`AshAuthzed.Adapter`) configurable per resource (`adapter` and `adapter_opts` in the `authzed` DSL block) or globally via application configuration.

### 1. Embedded Licet Adapter (`:licet` — Default)

Evaluates `.zed` schemas and stores relationship tuples inside your existing Postgres database via [`Licet`](https://hex.pm/packages/licet):

```elixir
# config/config.exs
import Config

config :ash_authzed,
  adapter: AshAuthzed.Adapters.Licet,
  adapter_opts: [instance: MyApp.Licet, consistency: :minimize_latency],
  schema_path: "priv/licet/user_permissions.yaml"
```

### 2. SpiceDB HTTP Adapter (`:spicedb_http`)

Communicates with a SpiceDB or AuthZed HTTP API (`/v1/permissions/check`, `/v1/permissions/resources`, `/v1/relationships/write`) using `Req`:

```elixir
# config/runtime.exs
import Config

config :ash_authzed,
  adapter: AshAuthzed.Adapters.SpiceDBHttp,
  adapter_opts: [
    url: System.fetch_env!("SPICEDB_HTTP_URL"),
    token: System.fetch_env!("SPICEDB_TOKEN")
  ]
```

---

## Usage in an `Ash.Resource`

Add `AshAuthzed` to `extensions` alongside `Ash.Policy.Authorizer`:

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  authzed do
    object_type "user_profile"
    actor_type "user"
    id_attribute :id
    adapter :licet
    adapter_opts instance: MyApp.Licet
    schema_path "priv/licet/user_permissions.yaml"

    # Writes: user_profile:<id>#owner@user:<id>
    relation :owner, subject_type: "user", subject_id: :id

    # Writes: user_profile:<id>#platform@platform:main
    relation :platform, static_subject: "platform:main"

    # Writes: platform:main#<mapped_role>@user:<id> (and deletes old role tuple on update!)
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

  # Note: AshAuthzed.Transformer automatically attaches AshAuthzed.SyncChange
  # to :create, :update, and :destroy actions!
  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:id, :name, :email, :role]
    end

    update :update_profile do
      accept [:name]
    end

    update :change_role do
      accept [:role]
    end
  end

  policies do
    policy action(:read) do
      authorize_if authzed_can(:view)
    end

    policy action(:update_profile) do
      authorize_if authzed_can(:edit)
    end

    policy action(:destroy) do
      authorize_if authzed_can(:delete)
    end

    policy action(:change_role) do
      forbid_unless authzed_can_assign(:role, on: "platform:main")
      authorize_if authzed_can(:change_role)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :email, :string, allow_nil?: false, public?: true

    attribute :role, :atom do
      allow_nil? false
      default :user
      public? true
      constraints one_of: [:user, :admin, :super_admin]
    end
  end
end
```

### Schema-First Resource & Policy Derivation (`from_zed` & `derive_policies`)

When your `.zed` file is the single source of truth, enable `from_zed` and `derive_policies` to automatically derive single-subject relations (matching `:<relation>_id` attributes on the resource) and `Ash.Policy.Authorizer` policies directly from your Zanzibar definition at compile time:

```elixir
defmodule MyApp.Workspace.Document do
  use Ash.Resource,
    domain: MyApp.Workspace,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  attributes do
    uuid_primary_key :id
    attribute :owner_id, :uuid, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :create, :update, :destroy]
  end

  authzed do
    object_type "document"
    from_zed "priv/authzed/schema.zed"
    # Or `derive_policies [view: :read, edit: :update, delete: :destroy]`
    derive_policies true

    # Explicit relations take precedence over auto-derived ones
    # (e.g. for static subjects or union/subject-set relations):
    relation :platform, static_subject: "platform:main"
  end
end
```

---

## Permission Modeling Patterns

`AshAuthzed` supports both classic role hierarchies and fine-grained capability permissions.

### Pattern 1: Role-Based Permissions (RBAC in ReBAC)

Map an attribute or relationship (such as `:role`) to Zanzibar relations and check coarse permissions (`:view`, `:edit`, `:delete`) in your Ash policies:

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  authzed do
    object_type "user_profile"
    schema_path "priv/licet/user_permissions.yaml"

    relation :owner, subject_type: "user", subject_id: :id
    relation :platform, static_subject: "platform:main"

    external_role :role,
      target: "platform:main",
      subject_type: "user",
      subject_id: :id,
      role_mapping: %{user: "member", admin: "admin", super_admin: "super_admin"}
  end

  policies do
    policy action_type(:read) do
      authorize_if authzed_can(:view)
    end
  end
end
```

### Pattern 2: Capability-Based Permissions (`admin` with Granular Capabilities)

Model granular action capabilities (`admin_create`, `admin_edit`, `admin_delete`) in your schema. A full `admin` automatically inherits all three capabilities, while delegated actors can be granted individual capabilities (such as `admin_edit` only) without receiving destructive `admin_delete` access.

**1. Define the schema (`.zed` or `.yaml`):**

```zed
definition user {}

definition catalog {
  // Full admin role
  relation admin: user

  // Optional direct capability grants
  relation can_create: user
  relation can_edit: user
  relation can_delete: user

  // Computed capabilities: full admin OR specific capability grant
  permission admin_create = admin + can_create
  permission admin_edit   = admin + can_edit
  permission admin_delete = admin + can_delete
}

definition managed_item {
  relation catalog: catalog
  relation admin: user
  relation can_create: user
  relation can_edit: user
  relation can_delete: user

  permission admin_create = admin + can_create + catalog->admin_create
  permission admin_edit   = admin + can_edit + catalog->admin_edit
  permission admin_delete = admin + can_delete + catalog->admin_delete
}
```

**2. Guard each Ash action with its specific capability:**

```elixir
defmodule MyApp.Catalog.ManagedItem do
  use Ash.Resource,
    domain: MyApp.Catalog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  authzed do
    object_type "managed_item"
    schema_path "priv/licet/admin_capabilities.yaml"

    # Links item to catalog: `managed_item:<id>#catalog@catalog:main`
    relation :catalog, static_subject: "catalog:main"

    # Syncs per-item capability (`managed_item:<id>#<capability>@user:<admin_id>`);
    # pass `target: "catalog:main"` when granting catalog-wide roles instead
    external_role :capability,
      subject_type: "user",
      subject_id: :admin_id
  end

  policies do
    policy action(:create) do
      authorize_if authzed_can(:admin_create, target: "catalog:main")
    end

    policy action(:update) do
      authorize_if authzed_can(:admin_edit)
    end

    policy action(:destroy) do
      authorize_if authzed_can(:admin_delete)
    end

    policy action_type(:read) do
      authorize_if authzed_can(:admin_edit)
    end
  end
end
```

---

## Testing (`async: true`)

`AshAuthzed` supports fast, isolated `async: true` ExUnit tests out of the box—either via `Licet` with Ecto's SQL Sandbox or via `AshAuthzed.Adapters.Memory`, which runs a caller-supervised in-memory tuple store without requiring Postgres or a SpiceDB container:

```elixir
defmodule MyApp.Accounts.UserPolicyTest do
  use ExUnit.Case, async: true

  setup do
    start_supervised!(
      {AshAuthzed.Adapters.Memory,
       name: MyTestAuthzed,
       schema: {:file, "priv/licet/schema.zed"},
       relationships: ["platform:main#super_admin@user:root"]}
    )

    :ok
  end

  test "authorizes profile updates for the owner" do
    user =
      MyApp.Accounts.User
      |> Ash.Changeset.for_create(:create, %{id: "u1", name: "Alice", email: "alice@example.com"})
      |> Ash.create!(authorize?: false)

    assert Ash.can?({user, :update_profile}, user)
  end
end
```

---

## Compile-Time Schema Verification

`AshAuthzed.Verifiers.VerifyZedSchema` runs automatically after DSL compilation and verifies against your `.zed` file or Licet `.yaml` validation bundle:

1. **`object_type` Existence**: Ensures `definition <object_type>` exists in your schema.
2. **Entity Relations (`relation` & `conditional_wildcard`)**: Ensures every declared relation exists on `definition <object_type>`.
3. **External Role Enum Exhaustiveness (`external_role`)**: Inspects the attribute's `one_of` constraints (or `Ash.Type.Enum` values), applies `role_mapping`, and verifies that every possible enum value maps to a defined `relation` on the target definition.
4. **Policy Checks (`authzed_can` & `authzed_can_assign`)**: Verifies that every permission checked in `policies` exists on the resource definition, and that every `assign_<role>` permission exists on the target definition for `authzed_can_assign`.

If any mismatch is detected, compilation fails immediately with a `Spark.Error.DslError` and a Jaro-distance `"Did you mean ...?"` hint.

---

## Mix Tasks

### Applying Schemas at Runtime (`mix ash_authzed.schema.apply`)

Push your `.zed` or `.yaml` Zanzibar schema directly to the configured ReBAC backend (`Licet`, `SpiceDBHttp`, or `Memory`) via `AshAuthzed.apply_schema/2` or the Mix task:

```bash
# Apply the default schema (`config :ash_authzed, :schema_path`) to the configured adapter
mix ash_authzed.schema.apply

# Apply an explicit .zed or .yaml schema file to SpiceDB
mix ash_authzed.schema.apply --schema priv/authzed/schema.zed --adapter spicedb_http
```

### Backfilling Existing Data (`mix ash_authzed.backfill`)

When adding `AshAuthzed` to an existing application with populated database tables, stream and reconcile relationship tuples in batches:

```bash
# Backfill all AshAuthzed resources in the current project
mix ash_authzed.backfill

# Backfill a specific resource with custom batch size
mix ash_authzed.backfill --resource MyApp.Accounts.User --batch-size 250

# Preview tuple operation counts without writing to the adapter
mix ash_authzed.backfill --dry-run
```

### Schema Validation (`zed validate` & `Licet.Validate`)

`AshAuthzed` ships with validation suites (`priv/licet/user_permissions.yaml` and `priv/licet/admin_capabilities.yaml`) that are compatible with both `Licet.Validate` (pure Elixir) and the official AuthZed CLI (`zed validate`):

```bash
# Validate using the AuthZed CLI (zero warnings)
zed validate priv/licet/user_permissions.yaml priv/licet/admin_capabilities.yaml

# Or run the ExUnit schema & contract validation suite
mix test test/ash_authzed/schema_validation_test.exs
```

### Benchmarking Adapters (`mix ash_authzed.bench`)

`AshAuthzed` includes a built-in benchmark and parity verification task (`lib/mix/tasks/ash_authzed.bench.ex`) that measures single create, bulk create (`after_batch/3`), `Ash.can?`, collection read (`lookup_resources`), and atomic bulk role updates across all supported backends:

```bash
# Run across all 4 backends (Memory, Licet on Postgres, SpiceDB on Memory, SpiceDB on Postgres)
mix ash_authzed.bench --all --count 500 --batch-size 100

# Run a specific adapter or comma-separated list (`memory`, `licet`, `spicedb_http`, `spicedb_postgres`)
mix ash_authzed.bench --adapter memory,licet --count 200

# Benchmark a custom Ash resource in your own application
mix ash_authzed.bench --resource MyApp.Accounts.User --count 200
```

#### External Tools & Dependencies for Live Benchmarks & Schema Testing

While `AshAuthzed.Adapters.Memory` and `Licet.Validate` run purely in Elixir with zero external dependencies, running the full live benchmark (`--all`) and CLI schema validation uses:

| Tool / Service | Used By | Purpose & Default Configuration |
| :--- | :--- | :--- |
| **[PostgreSQL](https://www.postgresql.org/)** (`>= 14`) | `AshAuthzed.Adapters.Licet`, `:spicedb_postgres` | Automatically provisions and tears down isolated temporary schemas/databases via `POSTGRES_URL` (defaults to `ecto://postgres:postgres@localhost/postgres`). |
| **[SpiceDB](https://github.com/authzed/spicedb)** (`spicedb` binary in `PATH`) | `AshAuthzed.Adapters.SpiceDBHttp` | Automatically spawns an ephemeral `spicedb serve` HTTP/gRPC server (and runs `spicedb datastore migrate head` for `:spicedb_postgres`) if `SPICEDB_URL` is not already running. |
| **[AuthZed CLI](https://github.com/authzed/zed)** (`zed` binary in `PATH`) | `zed validate` / `schema_validation_test.exs` | Validates `.zed` and `.yaml` schema definitions, relationship fixtures, and permission assertions offline and in GitHub Actions CI (`authzed/action-spicedb-validate@v1`). |

#### Reference Benchmark Results (500 records, batch size 100, full consistency)

| Adapter / Backend | 1x Create | Bulk Create (500 rows) | 1x `Ash.can?` | Read List (500 rows) | Atomic Bulk Update (50 rows) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`AshAuthzed.Adapters.Memory`** | `88.61 ms` | `171.18 ms` (`0.342 ms/row`) | `7.89 ms` | `28.91 ms` | `27.74 ms` |
| **`AshAuthzed.Adapters.Licet (PG)`** | `6.42 ms` | `819.39 ms` (`1.639 ms/row`) | `2.85 ms` | `34.28 ms` | `122.23 ms` |
| **`AshAuthzed.Adapters.SpiceDBHttp (Mem)`** | `4.16 ms` | `360.70 ms` (`0.721 ms/row`) | `1.27 ms` | `28.07 ms` | `77.13 ms` |
| **`AshAuthzed.Adapters.SpiceDBHttp (PG)`** | `7.25 ms` | `598.46 ms` (`1.197 ms/row`) | `7.57 ms` | `31.36 ms` | `110.09 ms` |

---

## Telemetry & Observability

`AshAuthzed.Adapter` wraps all permission checks, resource lookups, and tuple writes in `:telemetry` events so you can monitor authorization latency and batch sizes:

| Event | Measurements | Metadata |
| :--- | :--- | :--- |
| `[:ash_authzed, :check, :start \| :stop \| :exception]` | `duration`, `monotonic_time` | `adapter`, `resource`, `permission`, `subject`, `status` |
| `[:ash_authzed, :lookup_resources, :start \| :stop \| :exception]` | `duration`, `monotonic_time` | `adapter`, `resource_type`, `permission`, `subject`, `status` |
| `[:ash_authzed, :write_tuples, :start \| :stop \| :exception]` | `duration`, `monotonic_time` | `adapter`, `operation_count`, `operations`, `status` |
| `[:ash_authzed, :apply_schema, :start \| :stop \| :exception]` | `duration`, `monotonic_time` | `adapter`, `status` |
| `[:ash_authzed, :adapter, :write_tuples]` | `tuple_count` | `adapter`, `operations` |

Adapter and validation failures return structured `%AshAuthzed.Error{reason: atom(), details: term()}` exceptions.

---

## Documentation & AI Usage Rules

- **[Getting Started Tutorial](documentation/tutorials/getting-started-with-ash-authzed.md)** — Step-by-step guide to defining a `.zed` schema, configuring an adapter, and writing your first ReBAC policies.
- **[DSL Reference (`AshAuthzed`)](documentation/dsls/DSL-AshAuthzed.md)** — Complete reference for the `authzed` / `rebac` DSL sections, entities (`relation`, `external_role`, `conditional_wildcard`), and options.
- **[AI & LLM Usage Rules (`usage-rules.md`)](usage-rules.md)** — Ships with a [`usage_rules`](https://hex.pm/packages/usage_rules)-compatible rules file. Run `mix usage_rules.sync` to automatically inject `AshAuthzed` best practices into your project's `AGENTS.md` or `CLAUDE.md`.

---

## License

Released under the [MIT License](https://github.com/boxxxie/ash_authzed/blob/master/LICENSE).

