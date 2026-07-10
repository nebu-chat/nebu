---
name: feedback-logger-metadata-vs-report-content
description: Elixir Logger.info(map)/Logger.debug(fn -> map end) puts fields inside the rendered msg, NOT inside :logger meta -- a custom :logger handler reading meta.foo will see nil even though "foo" is visible in the human-readable log text
metadata:
  type: feedback
---

Confirmed empirically while reviewing `enhanced-logging/operational-log-store`
(cycle 0): calling `Logger.info(%{route_template: "/sync", ...})` produces a
`:logger` event where `meta` is ONLY Logger's own bookkeeping
(`pid`/`time`/`gl`/`domain` + whatever was explicitly passed via
`Logger.metadata/1` earlier in the same process) — the map's own keys
(`route_template`, `method`, `status`, ...) live exclusively inside
`msg: {:report, map}`. A custom `:logger` handler's `log/2` callback that does
`Map.get(log_event.meta, :route_template)` will ALWAYS get `nil` for a value
that was only ever put into the message map, never passed through
`Logger.metadata/1`.

**Why this matters for Nebu specifically:** `Nebu.Web.LogStore.Handler`
(the central `:logger` handler, `operational-log-store` story) extracts
`route_template`/`request_id` columns from `log_event.meta`, not from
`log_event.msg`. `Nebu.Web.Plugs.RequestLogger` set `request_id` correctly via
an explicit `Logger.metadata(request_id: ...)` call, but computed
`route_template` and only put it inside the `base_fields` message map — so
the dedicated `operational_logs.route_template` DB column (and its own index,
added specifically for this) ends up NULL for every HTTP-sourced row, even
though `route_template` is visible as a string inside the free-text
`message` column. This is silently invisible to tests that only assert the
substring appears in `ExUnit.CaptureLog`'s captured *text* output — that text
comes from the message/report, so it always contains the value; the DB-column
persistence gap is a separate, unverified claim.

**How to apply:** When reviewing any story that adds a field to a
`Logger.*` call and expects a custom `:logger` handler (or any code reading
`:logger`'s `meta`) to pick it up as STRUCTURED data (a DB column, a filter
key, a PubSub-consumer field lookup) — trace whether that field was passed via
`Logger.metadata/1` (goes into `meta`, structured, queryable) or merged into
the message/report map passed as the first arg to `Logger.info/debug/warn/error`
(goes into `msg`, only visible via re-parsing/inspecting text). "The string
appears in the captured log output" is NOT proof the handler's structured
extraction path also sees it — write/require a separate test that asserts on
the actual persisted-column/structured-lookup, not just the rendered text.

See [[feedback_redaction_wiring_gap]] for the sibling pattern (capability
exists, unit-tested, but not reachable from the real caller) — this is the
same failure shape one layer over: reachable syntactically, but through the
wrong Logger channel.

## Addendum (2026-07-05, admin-logs-monitoring-view cycle 6): `:mfa` vs `:module`

Empirically confirmed (via a throwaway `elixir script.exs` with a custom
`:logger` handler dumping `log_event.meta`): Elixir's `Logger.*` macros
ALWAYS auto-inject `meta.mfa = {CallingModule, function, arity}` — the
ENCLOSING named function/module at the macro's lexical call site, even when
the actual `Logger.debug(fn -> ... end)` call is textually nested inside an
anonymous function (e.g. a callback passed to `Plug.Conn.register_before_send`).
They NEVER inject a bare `meta.module` key. A custom `:logger` handler
(`Nebu.Web.LogStore.Handler.source_from_meta/1`) that keyed off `:module`
instead of `:mfa` therefore ALWAYS fell through to its fallback branch for
every real call in the app — only passing in tests that hand-built a
synthetic `meta: %{module: ...}` map instead of a real `:mfa` tuple. Fixed by
deriving the module from `:mfa`'s first tuple element first, falling back to
`:module` only for hand-crafted/unusual callers.

**How to apply:** any `:logger` handler code (or its tests) that reads
`log_event.meta` and matches/pattern-matches on `:module` specifically —
rather than `:mfa`'s first element — is almost certainly dead code for real
`Logger.*` calls. Verify claims about `:logger` metadata shape empirically
(a 5-line `elixir foo.exs` script with a probe handler is cheap and
authoritative) rather than trusting a fix's own comment describing Elixir
internals.
