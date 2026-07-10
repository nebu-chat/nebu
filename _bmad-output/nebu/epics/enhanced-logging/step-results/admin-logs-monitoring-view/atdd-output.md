# ATDD Output — admin-logs-monitoring-view

## Files created
- server/test/nebu/admin/logs_live_test.exs — 12 test cases (AT1-AT10, AT12; AT4 has 2 sub-cases)
- server/test/nebu/admin/logs_live/trace_map_bubble_test.exs — 3 test cases (AT11)

## Red confirmation
`cd server && mix test test/nebu/admin/logs_live_test.exs test/nebu/admin/logs_live/trace_map_bubble_test.exs`
0/14 passed, 1 excluded. All failures: UndefinedFunctionError for Nebu.Admin.LogsLive / Nebu.Admin.LogsLive.TraceMapBubble (module not available). Compiles cleanly with --warnings-as-errors, no syntax errors in test files.

## CRITICAL finding — PubSub message contract mismatch with story text
Real merged operational-log-store code (server/lib/nebu/web/log_store/handler.ex `safe_broadcast/1`):
`Phoenix.PubSub.broadcast(Nebu.PubSub, "operational_logs", entry)` where `entry` is a BARE MAP
(%{level:, source:, route_template:, request_id:, message:, metadata:}), NOT the
`{:operational_log_entry, entry_map}` tuple described in the story's Dev Notes / AC11.
Tests written against the REAL bare-map contract. Dev agent MUST pattern-match on the bare map
in handle_info/2, not the tuple form the story text describes.

## Second finding — HTTP metadata gap
RequestLogger plug logs method/path/status/duration_ms via Logger.info(base_fields_map), which
Handler.render_msg/1's {:report, report} clause renders into the `message` field via inspect/1 —
these fields do NOT currently survive into the `metadata` column. This contradicts the story's Dev
Notes ("extract the status from metadata.status"). Dev agent will need to either:
  (a) parse the inspected message string in LogsLive, or
  (b) fix Handler/RequestLogger to also populate metadata.status/method/path/duration_ms structurally
Option (b) is architecturally cleaner (matches the story's stated design) but touches the
already-committed operational-log-store code — flag for code-review/dev-story decision.

## Other assumptions
- data-testid/data-bubble-*/data-request-id attributes proposed by ATDD agent (documented in test moduledocs), mirrors existing data-step convention in bootstrap_live_test.exs
- pause_live_updates/resume_live_updates event names proposed for AC10 (story doesn't name a mechanism) — tagged @moduletag :proposed_contract
- Auth: mounted via live_isolated/3 bypassing router (matches AuditLogLive/BootstrapLive precedent)

## Not automatable in ExUnit (noted inline as comments)
- AT9: real Tab-order/Space/Enter keypress simulation — proxy via native <button> + aria attributes
- AT8/AT10: actual screen-reader announcement behavior — proxy via aria-label/aria-live="polite" markup presence
