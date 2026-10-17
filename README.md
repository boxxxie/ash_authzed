# AshAuthzed

[![Hex.pm](https://img.shields.io/hexpm/v/ash_authzed.svg)](https://hex.pm/packages/ash_authzed)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ash_authzed)
[![License](https://img.shields.io/hexpm/l/ash_authzed.svg)](https://github.com/boxxxie/ash_authzed/blob/master/LICENSE)

**Declarative Relationship-Based Access Control (ReBAC) and Zanzibar-style permissions for [Ash Framework](https://ash-hq.org/), featuring pluggable Licet (embedded Postgres), SpiceDB HTTP, and In-Memory adapters, compile-time `.zed` / YAML schema verification, and automatic batched tuple synchronization.**

`AshAuthzed` extends `Ash.Resource` with a declarative Spark DSL (`authzed` / `rebac`) that connects Ash's policy engine (`Ash.Policy.Authorizer`) and resource lifecycle hooks (`AshAuthzed.SyncChange`) to [`Licet`](https://hex.pm/packages/licet) or [AuthZed / SpiceDB](https://authzed.com/).

---

## Key Capabilities

- **Declarative Resource DSL (`AshAuthzed` / `AshRebac`)** — Configure Zanzibar `object_type`, direct `relation` tuples, `external_role` role-mapping tuples, and `conditional_wildcard` tags directly inside your `Ash.Resource` definition.
- **Compile-Time Schema Verification (`AshAuthzed.Verifiers.VerifyZedSchema`)** — Cross-checks your Ash resource's `object_type`, relations, enum role mappings, and policy check permissions against your `.zed` or `.yaml` schema at compile time with "Did you mean?" Jaro-distance suggestions. Also registers `@external_resource` so edits to your schema file automatically re-verify your Ash resources.
- **Pluggable Adapter Architecture (`AshAuthzed.Adapter`)**:
  - `AshAuthzed.Adapters.Licet` (`:licet`) — Embedded Elixir Zanzibar engine backed by your existing `Ecto.Repo` (Postgres) with native SQL Sandbox and transaction support.
  - `AshAuthzed.Adapters.SpiceDBHttp` (`:spicedb_http`) — Production HTTP/JSON client (`Req`) for external SpiceDB and AuthZed clusters (`/v1/permissions/*` and `/v1/relationships/write`).
  - `AshAuthzed.Adapters.Memory` (`:memory`) — Caller-supervised, zero-DB in-memory `Licet` store for sub-millisecond `async: true` ExUnit tests.
- **Native Ash Policy Checks (`AshAuthzed.Checks.Can` & `AshAuthzed.Checks.CanAssign`)** — Imported policy macros (`rebac_can/1,2` / `authzed_can/1,2` and `rebac_can_assign/2` / `authzed_can_assign/2`) that filter collection reads via `lookup_resources` and guard attribute/role assignments via `check?`.
- **Atomic & Bulk Lifecycle Tuple Sync (`AshAuthzed.SyncChange`)** — Automatically wired by `AshAuthzed.Transformer` onto `:create`, `:update`, and `:destroy` actions. Supports single-record actions, atomic updates (`atomic/3`), and batched `Ash.bulk_create!`, `Ash.bulk_update!`, and `Ash.bulk_destroy!` (`after_batch/3`) with operation deduplication.
- **Built-In Operational Mix Tasks**:
  - `mix ash_authzed.install` — Igniter-powered installer (`mix igniter.install ash_authzed`) for automatic project scaffolding.
  - `mix ash_authzed.backfill` (and alias `mix rebac.backfill`) — Streams existing database records in keyset-paginated batches and reconciles relationship tuples into Licet or SpiceDB.
  - `mix ash_authzed.bench` — Benchmarks single creates, bulk creates, `Ash.can?`, collection reads, and atomic bulk role promotions across adapters.

---

## Installation

### With Igniter (Recommended)

If your project uses [Igniter](https://hexdocs.pm/igniter), install and configure `ash_authzed` automatically:

```bash
# Default (embedded Licet + Ecto Repo)
mix igniter.install ash_authzed --yes

# Or configure for an external SpiceDB HTTP server
mix igniter.install ash_authzed --adapter spicedb --yes
```

### Manual Installation

Add `ash_authzed` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_authzed, "~> 0.1.0"},
    # Required only if using AshAuthzed.Adapters.SpiceDBHttp:
    {:req, "~> 0.5"}
  ]
end
```

Add `:ash_authzed` to your `.formatter.exs` so Spark DSL blocks and policy macros format without extra parentheses:

```elixir
[
  import_deps: [:ash, :ash_authzed],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

---

## Configuration & Adapters

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

### 3. Caller-Supervised In-Memory Adapter (`:memory`)

Runs `Licet` against an in-memory `Agent` tuple store—ideal for fast, isolated `async: true` tests without Postgres or Docker:

```elixir
start_supervised!(
  {AshAuthzed.Adapters.Memory,
   name: MyTestAuthzed,
   schema: {:file, "priv/licet/schema.zed"},
   relationships: ["platform:main#super_admin@user:root"]}
)
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

---

## Compile-Time Schema Verification

`AshAuthzed.Verifiers.VerifyZedSchema` runs automatically after DSL compilation and verifies against your `.zed` file or Licet `.yaml` validation bundle:

1. **`object_type` Existence**: Ensures `definition <object_type>` exists in your schema.
2. **Entity Relations (`relation` & `conditional_wildcard`)**: Ensures every declared relation exists on `definition <object_type>`.
3. **External Role Enum Exhaustiveness (`external_role`)**: Inspects the attribute's `one_of` constraints (or `Ash.Type.Enum` values), applies `role_mapping`, and verifies that every possible enum value maps to a defined `relation` on the target definition.
4. **Policy Checks (`rebac_can` & `rebac_can_assign`)**: Verifies that every permission checked in `policies` exists on the resource definition, and that every `assign_<role>` permission exists on the target definition for `rebac_can_assign`.

If any mismatch is detected, compilation fails immediately with a `Spark.Error.DslError` and a Jaro-distance `"Did you mean ...?"` hint.

---

## Mix Tasks

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

*(Note: `mix rebac.backfill` is also available as a convenience alias.)*

### Benchmarking Adapters (`mix ash_authzed.bench`)

Run the built-in benchmark suite to measure single create, bulk create (`after_batch/3`), `Ash.can?`, collection read (`lookup_resources`), and atomic bulk role updates across adapters:

```bash
mix ash_authzed.bench --count 200
mix ash_authzed.bench --count 200 --compare-spicedb
```

---

## Telemetry & Error Handling

- **Telemetry**: `AshAuthzed.Adapter` wraps operations in `:telemetry.span/3` events:
  - `[:ash_authzed, :check, :start | :stop | :exception]`
  - `[:ash_authzed, :lookup_resources, :start | :stop | :exception]`
  - `[:ash_authzed, :write_tuples, :start | :stop | :exception]`
  - `[:ash_authzed, :adapter, :write_tuples]` (emits `%{tuple_count: count}` measurements for batch verification)
- **Structured Exceptions**: Adapter and validation failures return `%AshAuthzed.Error{reason: atom(), details: term()}` exceptions.

---

## Architecture Overview

```text
lib/
├── ash_authzed.ex                         # Spark DSL extension, backfill/2, and AshRebac alias
├── ash_authzed/
│   ├── adapter.ex                         # Behaviour contract & telemetry dispatcher
│   ├── adapters/
│   │   ├── licet.ex                       # Embedded Postgres/Ecto Licet adapter
│   │   ├── spicedb_http.ex                # SpiceDB HTTP/JSON client adapter (Req)
│   │   └── memory.ex                      # Caller-supervised in-memory Licet adapter
│   ├── checks.ex                          # Ash.Policy.FilterCheck (Can) & SimpleCheck (CanAssign)
│   ├── error.ex                           # Structured AshAuthzed.Error exception
│   ├── sync_change.ex                     # Ash.Resource.Change (atomic + after_batch tuple sync)
│   ├── transformer.ex                     # Spark DSL transformer & PolicyMacros (rebac_can)
│   └── verifiers/
│       └── verify_zed_schema.ex           # Compile-time .zed / YAML schema verifier
└── mix/tasks/
    ├── ash_authzed.install.ex             # Igniter project installer
    ├── ash_authzed.backfill.ex            # Relationship tuple backfill task
    ├── ash_authzed.bench.ex               # Adapter performance benchmark task
    └── rebac.backfill.ex                  # Delegated alias for ash_authzed.backfill
```

---

## License

Released under the [MIT License](https://github.com/boxxxie/ash_authzed/blob/main/LICENSE).
