# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-17

### Added

- **Schema-First Resource & Policy Derivation**:
  - Added `from_zed`, `definition`, `derive_relations`, and `derive_policies` options to the `authzed` and `rebac` DSL sections.
  - `AshAuthzed.Transformer` automatically derives `%AshAuthzed.Relation{}` entities from `.zed` / `.yaml` definitions when matching `:<relation>_id` attributes exist on the resource, while preserving explicit DSL overrides.
  - `derive_policies` automatically synthesizes `Ash.Policy.Authorizer` policies from `.zed` permissions (`true` for standard mappings or a custom keyword list/map), grouping permissions by Ash `action_type` with `OR` semantics.
- **Runtime Schema Lifecycle (`apply_schema/2` & Mix Task)**:
  - Added `AshAuthzed.apply_schema/2` and the `AshAuthzed.Adapter.apply_schema/2` callback across `AshAuthzed.Adapters.Licet` (`Licet.write_schema/3`), `AshAuthzed.Adapters.SpiceDBHttp` (`POST /v1/schema/write`), and `AshAuthzed.Adapters.Memory`, with `:telemetry.span/3` instrumentation (`[:ash_authzed, :apply_schema, :start | :stop | :exception]`).
  - Added `mix ash_authzed.schema.apply` to push `.zed` or `.yaml` schemas to the configured adapter from the CLI.

## [0.1.0] - 2026-10-17

### Added

- Declarative `AshAuthzed` (`AshRebac`) Spark DSL extension for `Ash.Resource` with `object_type`, `relation`, `external_role` (including `target: :self` and `subject_attribute` dynamic templates), and `conditional_wildcard` entities.
- Native `Ash.Policy.Authorizer` policy check macros (`authzed_can/1,2`, `authzed_can_assign/2`, `rebac_can/1,2`, and `rebac_can_assign/2`) supporting both record-scoped (`filter`/`check`) and static target (`on:` / `target:`) checks.
- Automatic lifecycle tuple synchronization via `AshAuthzed.SyncChange` supporting single-record actions, atomic updates, and deduplicated `after_batch/3` bulk operations (`Ash.bulk_create!`, `Ash.bulk_update!`, `Ash.bulk_destroy!`).
- Compile-time `.zed` and `.yaml` schema drift verifier (`AshAuthzed.Verifiers.VerifyZedSchema`) with Jaro-distance suggestions, static target and dynamic template validation, and `@external_resource` tracking.
- Pluggable adapter behaviour (`AshAuthzed.Adapter`) with `:telemetry` instrumentation and three built-in adapters:
  - `AshAuthzed.Adapters.Licet` (embedded Postgres-backed Zanzibar engine)
  - `AshAuthzed.Adapters.SpiceDBHttp` (SpiceDB / AuthZed HTTP API via `Req`)
  - `AshAuthzed.Adapters.Memory` (caller-supervised in-memory store for `async: true` tests)
- Mix tasks: `mix ash_authzed.install` (Igniter installer), `mix ash_authzed.backfill` (keyset-paginated tuple reconciliation), and `mix ash_authzed.bench` (adapter throughput benchmark suite).
- Dual permission modeling examples, validation fixtures (`priv/licet/user_permissions.yaml` and `priv/licet/admin_capabilities.yaml`), and ExDoc / LLM guides (`Getting Started`, `DSL: AshAuthzed`, `usage-rules.md`) covering both Role-Based (RBAC in ReBAC) and Capability-Based (`admin_create`, `admin_edit`, `admin_delete`) patterns.
