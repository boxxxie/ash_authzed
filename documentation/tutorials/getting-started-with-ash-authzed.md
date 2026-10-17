# Getting Started with AshAuthzed

`AshAuthzed` brings Google Zanzibar-style Relationship-Based Access Control (ReBAC) to [Ash Framework](https://ash-hq.org/). Instead of scattering complex role joins across dozens of resource policies, you declare how your Ash resources map to Zanzibar objects, relations, and roles, and `AshAuthzed` handles **compile-time schema verification**, **batched tuple synchronization**, and **policy evaluation**.

In this guide, you will learn how to:

1. Choose and configure an adapter (`Licet`, `SpiceDBHttp`, or `Memory`).
2. Author a ReBAC schema (`user_permissions.yaml` or `.zed`).
3. Configure the `authzed` DSL on an `Ash.Resource` (`relation`, `external_role`, and `conditional_wildcard`).
4. Write authorization policies with `rebac_can/1,2` and `rebac_can_assign/2`.
5. Backfill existing database records using `mix ash_authzed.backfill`.

---

## 1. Installation

### Using Igniter (Recommended)

If your application includes [Igniter](https://hexdocs.pm/igniter), run:

```bash
mix igniter.install ash_authzed --yes
```

### Manual Installation

Add `:ash_authzed` to `mix.exs`:

```elixir
def deps do
  [
    {:ash_authzed, "~> 0.2.0"},
    # Required only if using AshAuthzed.Adapters.SpiceDBHttp:
    {:req, "~> 0.5"}
  ]
end
```

Add `:ash_authzed` to `.formatter.exs` so DSL blocks format cleanly:

```elixir
[
  import_deps: [:ash, :ash_authzed],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

---

## 2. Choosing an Adapter

`AshAuthzed` implements a pluggable `AshAuthzed.Adapter` behaviour with three built-in backends:

| Adapter | Best For | Storage & Schema |
| :--- | :--- | :--- |
| `AshAuthzed.Adapters.Licet` (`:licet`) | Single-app Elixir/Phoenix deployments that want ReBAC inside their existing Postgres database without running a separate service. | Uses your Ecto Postgres repo via `Licet` + a `.zed` or YAML validation bundle (`priv/licet/user_permissions.yaml`). |
| `AshAuthzed.Adapters.SpiceDBHttp` (`:spicedb_http`) | Multi-service architectures or high-scale deployments using a dedicated [SpiceDB](https://authzed.com/spicedb) or AuthZed cluster. | Communicates over HTTP/JSON (`Req`) with a SpiceDB server (`/v1/permissions/*`, `/v1/relationships/write`). |
| `AshAuthzed.Adapters.Memory` (`:memory`) | Fast, isolated `async: true` unit tests and CI pipelines without external infrastructure. | Caller-supervised in-memory `Licet` tuple store. |

### Option A: Configuring `Licet` (Embedded Postgres)

```elixir
# config/config.exs
import Config

config :ash_authzed,
  adapter: AshAuthzed.Adapters.Licet,
  adapter_opts: [instance: MyApp.Licet, consistency: :minimize_latency],
  schema_path: "priv/licet/user_permissions.yaml"
```

### Option B: Configuring `SpiceDBHttp` (SpiceDB / AuthZed HTTP)

```elixir
# config/runtime.exs
import Config

config :ash_authzed,
  adapter: AshAuthzed.Adapters.SpiceDBHttp,
  adapter_opts: [
    url: System.fetch_env!("SPICEDB_HTTP_URL"),
    token: System.fetch_env!("SPICEDB_TOKEN")
  ],
  schema_path: "priv/authzed/schema.zed"
```

### Option C: Configuring `Memory` for Tests

```elixir
start_supervised!(
  {AshAuthzed.Adapters.Memory,
   name: MyTestAuthzed,
   schema: {:file, "priv/licet/schema.zed"}}
)
```

---

## 3. Designing Your Schema

Before wiring up a resource, define your object types, relations, and permissions. `AshAuthzed.Verifiers.VerifyZedSchema` inspects this schema at compile time to ensure your Ash resources never reference undefined object types, relations, or permissions.

```zed
definition user {}

definition platform {
  relation super_admin: user
  relation admin: user
  relation member: user

  permission assign_user        = super_admin + admin
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
```

---

## 4. Configuring the `authzed` DSL on an `Ash.Resource`

Add `AshAuthzed` to `extensions` and `Ash.Policy.Authorizer` to `authorizers`. Inside the `authzed` block, map your resource's attributes to Zanzibar tuples:

- **`relation`**: Syncs a direct relationship tuple (`subject_type` + `subject_id` attribute, or `static_subject`).
- **`external_role`**: Syncs an enum/role attribute on the resource to a relation on an external `target` object (`target: "platform:main"`), with optional `role_mapping` and automatic old-role tuple cleanup on update.
- **`conditional_wildcard`**: Syncs a wildcard relation (`subject_type:*`) when `attribute` is in the configured `in` list.

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

    relation :owner, subject_type: "user", subject_id: :id
    relation :platform, static_subject: "platform:main"

    external_role :role,
      target: "platform:main",
      subject_type: "user",
      subject_id: :id,
      role_mapping: %{user: "member", admin: "admin", super_admin: "super_admin"}

    conditional_wildcard :is_protected_admin,
      subject_type: "user",
      attribute: :role,
      in: [:admin, :super_admin]
  end

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

During compilation:
1. `AshAuthzed.Transformer` attaches `AshAuthzed.SyncChange` to `:create`, `:update`, and `:destroy` actions and registers `@external_resource` for `schema_path` (and derives relations/policies when `from_zed: true` / `derive_policies: true` are set).
2. `AshAuthzed.Verifiers.VerifyZedSchema` verifies that `user_profile`, `owner`, `platform`, `is_protected_admin`, and all mapped `external_role` relations exist in your schema.

---

## 5. Writing Policies with `authzed_can/1,2` and `authzed_can_assign/2`

Add a `policies` block to your resource using the imported `AshAuthzed.PolicyMacros` (or set `from_zed: true` and `derive_policies: true` to auto-generate standard action policies directly from your `.zed` permissions):

```elixir
  policies do
    # 1. Read actions: filters the query via `lookup_resources` to only records the actor can `:view`
    policy action(:read) do
      authorize_if authzed_can(:view)
    end

    # 2. Update & Destroy actions: checks `:edit` / `:delete` permission on the target record
    policy action(:update_profile) do
      authorize_if authzed_can(:edit)
    end

    policy action(:destroy) do
      authorize_if authzed_can(:delete)
    end

    # 3. Role Assignment: verifies both `platform:main#assign_<new_role>` AND `user_profile:<id>#change_role`
    policy action(:change_role) do
      forbid_unless authzed_can_assign(:role, on: "platform:main")
      authorize_if authzed_can(:change_role)
    end
  end
```

---

## 6. Applying Schemas & Backfilling Existing Data

### Applying Your Schema (`mix ash_authzed.schema.apply`)

Push your `.zed` or `.yaml` schema file directly to your configured backend (`Licet`, `SpiceDBHttp`, or `Memory`):

```bash
mix ash_authzed.schema.apply
```

### Backfilling Existing Data (`mix ash_authzed.backfill`)

If you are integrating `AshAuthzed` into an application that already has rows in PostgreSQL, run the backfill task to stream and reconcile relationship tuples in batches:

```bash
mix ash_authzed.backfill
```

---

## 7. Benchmarking and Telemetry

### Telemetry Events
`AshAuthzed.Adapter` emits `:telemetry.span/3` events (`[:ash_authzed, :check, ...]`, `[:ash_authzed, :lookup_resources, ...]`, `[:ash_authzed, :write_tuples, ...]`, and `[:ash_authzed, :apply_schema, ...]`) so you can monitor latency and batch sizes in production.

### Benchmarking Adapters
To compare throughput and latency across `Memory`, `Licet`, and `SpiceDBHttp`, run:

```bash
mix ash_authzed.bench --count 200
```

---

## 8. Going Further: Fine-Grained Capabilities (`admin_create`, `admin_edit`, `admin_delete`)

While the `User` profile walkthrough above models classic coarse roles (`super_admin`, `admin`, `member`), Zanzibar schemas also let you decompose roles into **action-level capabilities** without changing your adapter configuration.

For example, in `priv/licet/admin_capabilities.yaml`, a full `admin` automatically inherits `admin_create`, `admin_edit`, and `admin_delete`, while delegated users can be granted individual capabilities (such as `can_edit` -> `admin_edit`) without receiving destructive `admin_delete` access:

```zed
definition user {}

definition catalog {
  relation admin: user
  relation can_create: user
  relation can_edit: user
  relation can_delete: user

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

In your `Ash.Resource`, each action checks its corresponding capability via `authzed_can/1,2`:

```elixir
defmodule MyApp.Catalog.ManagedItem do
  use Ash.Resource,
    domain: MyApp.Catalog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  authzed do
    object_type "managed_item"
    schema_path "priv/licet/admin_capabilities.yaml"

    relation :catalog, static_subject: "catalog:main"

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

