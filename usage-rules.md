# AshAuthzed Usage Rules

`AshAuthzed` (also aliased as `AshRebac`) provides Zanzibar-style Relationship-Based Access Control (ReBAC) for `Ash.Resource` modules via `Ash.Policy.Authorizer`, automatic batched tuple lifecycle synchronization (`AshAuthzed.SyncChange`), compile-time schema drift verification (`AshAuthzed.Verifiers.VerifyZedSchema`), and pluggable backends (`Licet`, `SpiceDBHttp`, and `Memory`).

## Core Invariants

1. **Always Include Both Extensions**: Every resource using `AshAuthzed` MUST include `authorizers: [Ash.Policy.Authorizer]` and `extensions: [AshAuthzed]` in `use Ash.Resource`.
2. **Never Manually Add `AshAuthzed.SyncChange` to Actions**: `AshAuthzed.Transformer` automatically attaches `change {AshAuthzed.SyncChange, on: [:create, :update, :destroy]}` and registers `@external_resource` for `schema_path`. Do not manually add `change AshAuthzed.SyncChange` inside individual actions.
3. **Compile-Time Schema Alignment**: `AshAuthzed.Verifiers.VerifyZedSchema` validates `object_type`, `relation`, `external_role`, `conditional_wildcard`, `rebac_can`, and `rebac_can_assign` against your configured `.zed` or `.yaml` schema at compile time. Always update your schema file before referencing new relations or permissions in a resource.
4. **Consult Generated DSL Docs**: For exact option types and defaults, check `documentation/dsls/DSL-AshAuthzed.md` or run `mix usage_rules.search_docs "AshAuthzed"`.

---

## Resource DSL (`authzed` / `rebac`)

```elixir
# ✅ DO: Declare `object_type`, `relation`, `external_role`, and `conditional_wildcard` in the `authzed` block
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

    # Direct relation: user_profile:<id>#owner@user:<id>
    relation :owner, subject_type: "user", subject_id: :id

    # Static subject relation: user_profile:<id>#platform@platform:main
    relation :platform, static_subject: "platform:main"

    # External role relation on another object: platform:main#<mapped_role>@user:<id>
    # Automatically deletes old role tuples on update or backfill reconciliation!
    external_role :role,
      target: "platform:main",
      subject_type: "user",
      subject_id: :id,
      role_mapping: %{user: "member", admin: "admin", super_admin: "super_admin"}

    # Wildcard tag: user_profile:<id>#is_protected_admin@user:* when role in [:admin, :super_admin]
    conditional_wildcard :is_protected_admin,
      subject_type: "user",
      attribute: :role,
      in: [:admin, :super_admin]
  end
end

# ❌ DON'T: Do not invent `resource_type`, `field:`, `condition: expr(...)`, or nested `sync do ... end` blocks
```

---

## Authorization Policies (`authzed_can/1,2` & `authzed_can_assign/2`)

`AshAuthzed.PolicyMacros` is automatically imported into every resource that uses `AshAuthzed`:

- **`authzed_can(permission, opts \\ [])`** (alias `rebac_can/1,2`):
  - Expands to `{AshAuthzed.Checks.Can, [permission: permission, ...]}` (`Ash.Policy.FilterCheck`).
  - On **read** actions, filters queries via `AshAuthzed.Adapter.lookup_resources/4` (`expr(^ref(id_attr) in ^allowed_ids)`).
  - On **update/destroy** actions and `Ash.can?`, checks whether the current actor holds `permission` on the target record(s).
  - On **create** actions (where the record does not exist yet in the ReBAC store), pass `target: "type:id"` (or `on: "type:id"`) to evaluate `permission` on the parent container object via `AshAuthzed.Adapter.check?/4`.
- **`authzed_can_assign(attribute, opts)`** (alias `rebac_can_assign/2`):
  - Expands to `{AshAuthzed.Checks.CanAssign, [attribute: attribute, on: target, ...]}` (`Ash.Policy.SimpleCheck`).
  - Inspects the incoming attribute value on create/update changesets and verifies `Adapter.check?(opts[:on] || opts[:target], "#{prefix}#{new_val}", subject, adapter_opts)` (defaults to `prefix: "assign_"`).

```elixir
# ✅ DO: Use `authzed_can/1` for resource permissions and `authzed_can_assign/2` for role/attribute assignment guards
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

# ✅ DO: Prefer capability-named permissions in `authzed_can/1,2` (e.g., `authzed_can(:admin_create, target: "catalog:main")`,
# `authzed_can(:admin_edit)`, `authzed_can(:admin_delete)`) over checking role names directly in Ash
# policies. For `:create` actions (where the record ID does not exist yet in the ReBAC store), pass
# `target: "type:id"` (or `on: "type:id"`) to evaluate the capability on the parent/container object synchronously:
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

# ❌ DON'T: Check coarse role names or raw attributes in Ash policies when capabilities
# are modeled in your schema—this bypasses delegated capability grants (like `can_edit`):
policies do
  policy action(:update) do
    # Bad: blocks actors who have `can_edit` or inherited `catalog->admin_edit`
    authorize_if authzed_can(:admin)
  end
end
```

---

## Adapters & Testing (`async: true`)

| Adapter | Module | Key Options |
| :--- | :--- | :--- |
| `:licet` | `AshAuthzed.Adapters.Licet` | `instance: MyApp.Licet`, `consistency: :minimize_latency \| :full`, `write_mode: :touch \| :create` |
| `:spicedb_http` | `AshAuthzed.Adapters.SpiceDBHttp` | `url: "http://localhost:8443"`, `token: "secret"`, `req_options: [...]` |
| `:memory` | `AshAuthzed.Adapters.Memory` | `store: MyTestStore`, `timeout: 5_000` |

### Testing Rules
- **Caller-Supervised Memory Store**: Start `AshAuthzed.Adapters.Memory` via `start_supervised!/1` with a unique `:name` per test for `async: true` safety.
- **Seed Fixtures with `authorize?: false`**: When creating prerequisite records in test `setup` blocks, pass `authorize?: false` so `AshAuthzed.SyncChange` writes initial tuples without requiring an already-authorized actor.
- **Asserting Read vs. Write Policies**:
  - **Reads** filter unauthorized records rather than raising: assert on the returned list.
  - **Mutations** raise `Ash.Error.Forbidden`: assert with `assert_raise Ash.Error.Forbidden, fn -> ... end`.

---

## Operational Mix Tasks

- `mix igniter.install ash_authzed --yes` — Installs and configures `AshAuthzed` via Igniter (always pass `--yes` in non-interactive sessions).
- `mix ash_authzed.backfill` — Streams existing Ash resources and reconciles relationship tuples in batches (`--resource`, `--domain`, `--batch-size`, `--dry-run`, `--no-reconcile`).
- `mix ash_authzed.bench` — Benchmarks single creates, bulk creates, `Ash.can?`, collection reads, and atomic bulk updates across adapters.
- `mix spark.cheat_sheets --extensions AshAuthzed` — Regenerates `documentation/dsls/DSL-AshAuthzed.md` after modifying the Spark DSL schema.
