# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-17

### Added

- Declarative `AshAuthzed` (`AshRebac`) Spark DSL extension for `Ash.Resource` with `object_type`, `relation`, `external_role`, and `conditional_wildcard` entities.
- Native `Ash.Policy.Authorizer` policy check macros (`authzed_can/1,2`, `authzed_can_assign/2`, `rebac_can/1,2`, and `rebac_can_assign/2`).
- Automatic lifecycle tuple synchronization via `AshAuthzed.SyncChange` supporting single-record actions, atomic updates, and deduplicated `after_batch/3` bulk operations (`Ash.bulk_create!`, `Ash.bulk_update!`, `Ash.bulk_destroy!`).
- Compile-time `.zed` and `.yaml` schema drift verifier (`AshAuthzed.Verifiers.VerifyZedSchema`) with Jaro-distance suggestions and `@external_resource` tracking.
- Pluggable adapter behaviour (`AshAuthzed.Adapter`) with `:telemetry` instrumentation and three built-in adapters:
  - `AshAuthzed.Adapters.Licet` (embedded Postgres-backed Zanzibar engine)
  - `AshAuthzed.Adapters.SpiceDBHttp` (SpiceDB / AuthZed HTTP API via `Req`)
  - `AshAuthzed.Adapters.Memory` (caller-supervised in-memory store for `async: true` tests)
- Mix tasks: `mix ash_authzed.install` (Igniter installer), `mix ash_authzed.backfill` (keyset-paginated tuple reconciliation), and `mix ash_authzed.bench` (adapter throughput benchmark suite).
- Comprehensive ExDoc guides (`Getting Started`, `DSL: AshAuthzed`) and `usage-rules.md` for LLM/agent integration.
