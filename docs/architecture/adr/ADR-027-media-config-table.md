# ADR-027: Admin-Configurable Media Policy via a Dedicated `media_config` Table

## Status

Accepted - 2026-07-06

Builds on: ADR-020 (Public-API rule / module architecture), ADR-022 (OIDC
bootstrap-only configuration — the pattern this ADR follows for a second domain).
Part of: Epic `media-security-admin-control`, Story 9.

## Context

This epic introduces a growing list of runtime-configurable policy values that were
originally hardcoded in `config.exs`: upload/scan size limits, pending-upload limits,
retention windows, webhook URL, MIME denylist, and (via Story 13) the media lifecycle
policy. These values must be changeable from `/admin/media/settings` without a redeploy,
following the precedent ADR-022 set for OIDC configuration.

Two options were evaluated:

- **A new, dedicated `media_config` table** (`key TEXT PRIMARY KEY, value TEXT NOT NULL,
  set_at BIGINT NOT NULL`), with `Nebu.Media.Config` as the sole public-API write seam
  (ADR-020).
- **Extending the existing `server_config` table** (used for OIDC bootstrap config) with
  media-specific keys.

## Decision

Nebu introduces a **dedicated `media_config` table**, not an extension of
`server_config`. `Nebu.Media.Config` is the only module that writes to it, exposing
`get/0` (DB override with fallback to the `config.exs` default) and `upsert/1`.

Cache invalidation across cluster nodes reuses the **already-established `:pg`
process-group broadcast pattern** from `Nebu.Web.OidcConfig` (Erlang `:pg`, not
Phoenix.PubSub) — every node joins a `:pg` group and broadcasts an invalidation to the
other members on `upsert/1`. This is combined with a low-default TTL fallback so a node
that misses a broadcast (e.g. during a network partition) does not serve a stale
security-relevant value indefinitely. See Story 9a's acceptance criteria for the exact
mechanism.

Every configuration change writes a `media_config_updated` audit-log entry with
`%{key, old_value, new_value}`.

A direct consequence: the Story 7 first-draft decision "`webhook_url` is ops-only,
configured via `config.exs`" is revised — `webhook_url` becomes admin-configurable via
`media_config` from Story 9b onward.

## Consequences

### Positive
- Clear ownership boundary (ADR-020): `media_config` changes never trigger
  media-unrelated cache invalidation, and `server_config` changes never trigger
  media-related invalidation.
- Reuses a proven, already-implemented cluster-invalidation mechanism instead of
  inventing a second one.

### Negative / risks
- A second config table alongside `server_config` means two parallel
  "runtime-configurable value" subsystems in the codebase. Accepted as the lesser cost
  compared to entangling two unrelated domains' cache-invalidation behavior.

## Related

- Epic `media-security-admin-control`, Stories 9a, 9b, 9c.
- ADR-020 — Clustering Strategy & Module Architecture (Public-API rule).
- ADR-022 — OIDC Bootstrap-Only Configuration (the pattern this ADR follows).
