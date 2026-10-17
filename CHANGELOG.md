# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
