# Code Review Report — war-room-mode (cycle 0)

## MAJOR-1 (fix directly — unambiguous bug, clear fix, not a design tradeoff)
`server/lib/nebu/web/plugs/request_logger.ex` — `Logger.metadata(user_id: conn.assigns[:current_user], device_id: conn.assigns[:device_id])`
logs the RAW `conn.assigns.current_user` value. On Matrix (`/_matrix/*`) routes this is a
plain string user_id (safe, as design-decisions.md #5 intended). But `RequestLogger` also
runs on `/admin/*` routes (same top-level `Nebu.Web.Router`), where
`Nebu.Admin.Auth.fetch_current_user/2` assigns `:current_user` = a MAP containing
`"email"`, `"sub"`, `"admin"`, `"matrix_user_id"`, session-timing fields.
`Handler.safe_metadata/1` recurses into maps, so an admin's EMAIL flows into
`metadata["user_id"]` — broadcast unconditionally to the live `/admin/logs` stream (every
admin viewing the page sees other admins' emails) and persisted whenever
info/debug/war-room collection is active. NEW leak introduced by this story (RequestLogger
previously logged no user_id/device_id at all). security_review:required — this is exactly
the LAW's PII concern.

Fix direction: extract a bare identifier string from `conn.assigns.current_user` regardless
of shape (map → `"matrix_user_id"`/`"sub"`; string → itself; else → nil) before passing to
`Logger.metadata/1`. Never log the raw assign value.

## MINOR-1 (fix directly)
AC7's broad-scope warning is shown for explicit `scope="all"` but NOT for the default/empty
`""` select value, which is exactly the NULL-scope case AC7 also requires a warning for (the
broadest, most dangerous case — the /sync-flooding footgun AC7/AC8 exist to prevent).
`app.js`'s `wireWarRoomPanel` else-branch hides both warnings on `""`. Fix: treat `""` the
same as `"all"` for warning-display purposes.

## MINOR-2 (fix directly)
`parse_int_bounded/4` in `logs_live.ex` silently substitutes the hard-coded default
(100/300) for any out-of-range `max_entries`/`max_duration_s` value with no flash/error —
an admin who bypasses the HTML min/max (edited value, crafted phx-submit) gets a silently
different value than what they submitted. Fix: clamp to the bound or return an error,
whichever is simpler given the existing validation-error plumbing.

## INFO (accepted, no action)
- AC8 numeric caps are advisory/client-side only — deliberate, matches sibling precedent.
- AC3 negative-param contract (`{:error, :invalid_params, msg}`) exists and is handled
  gracefully but untested; low-risk, UI makes it practically unreachable.
- `started_by` "unknown-admin" fallback is defensive-only (on_mount gate guarantees a
  populated session).
- Public-route metadata gets harmless `"user_id": null, "device_id": null`.

## Scrutiny checklist: 6/7 PASS (atomicity, should_persist override, DB unique-index
backstop, timer survival, AC12 UUID normalization, access control/auditability all verified
correct). Only #5 (RequestLogger redaction/PII path) failed — MAJOR-1 above.

## Decision
MAJOR-1 is an unambiguous bug with a clear, uncontroversial fix (extract identifier, don't
log raw assign) — not a design tradeoff. Per this epic's established headless-session
pattern, fixing directly via dev-story cycle 1 rather than stopping to ask, along with
MINOR-1/MINOR-2.
