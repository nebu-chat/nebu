---
name: assign-key-shape-differs-per-route
description: A conn.assigns key logged/persisted as an "identifier" is a plain string on one router but a full struct/map (with PII) on another — grep ALL assign sites, not just the one the design doc cites
metadata:
  type: feedback
---

When a change logs `conn.assigns[:some_id]` into Logger.metadata / persisted log
metadata and justifies it as "just an identifier, not sensitive", verify the
assign has that shape on EVERY router/pipeline that runs the plug — not only the
one the design doc reasoned about.

**Why:** war-room-mode added `Logger.metadata(user_id: conn.assigns[:current_user])`
in `Nebu.Web.Plugs.RequestLogger` (a plug in the top-level `Nebu.Web.Router` that
runs for `/_matrix/*` AND `/admin/*` via `dispatch_admin`). The design doc verified
only `OidcPlug`, which assigns `:current_user` = a plain string user_id. But
`Nebu.Admin.Auth.fetch_current_user/2` assigns `:current_user` = a MAP containing
`email`, `sub`, `matrix_user_id`, `session_exp`, `admin`. `Handler.safe_metadata`
recurses into maps (`is_map` -> keeps binaries), so admin email + session-timing
leaked into log metadata — always broadcast to the live `/admin/logs` stream, and
persisted whenever info/debug collection or a war room is active. The
"it's just an identifier" justification was true for one route, false for another.

**How to apply:** For any log/persist of a conn assign, `grep -rn "assign(:KEY"
server/lib/` across ALL namespaces (Matrix, Admin, Media). If ANY site assigns a
struct/map rather than the bare id, that's a MAJOR sensitive-data-in-logs leak
(project has a "No Sensitive Data in Logs" LAW covering credentials AND PII).
Global plugs in `Nebu.Web.Router` run for `/admin` too — admin routes aren't
started in the test env, so this class of leak is invisible to the test suite.
Related: [[feedback_no_sensitive_data_in_logs_law]] (does not exist here yet),
[[feedback_redaction_wiring_gap]].
