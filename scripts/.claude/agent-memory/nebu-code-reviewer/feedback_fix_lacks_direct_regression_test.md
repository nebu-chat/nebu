---
name: feedback-fix-lacks-direct-regression-test
description: a request_logger.ex/handler.ex metadata-flow fix shipped with zero test asserting the actual produced shape - test-review's fix-recommendation absorbed the "what" but not "prove it with a test"
metadata:
  type: feedback
---

In `admin-logs-monitoring-view` (enhanced-logging epic), test-review finding
#4 (pre-dev) correctly diagnosed that `RequestLogger` never called
`Logger.metadata(method:, status:, duration_ms:)`, so those fields never
reached `Nebu.Web.LogStore.Handler.parse_log_event/1`'s `metadata` map — only
the `inspect/1`-rendered message text. It recommended the fix as
"implementation guidance carried forward" into dev-story. The dev agent
applied the fix correctly (verified by manual code trace: `Logger.metadata/1`
call site, `@drop_meta_keys` doesn't strip method/status/duration_ms,
`safe_metadata/1` stringifies keys) — but added ZERO test asserting the
actual end-to-end shape. `request_logger_test.exs` (untouched by the diff)
only asserts the rendered debug-payload JSON string (pre-existing, unrelated
coverage). `handler_test.exs` (pre-existing, untouched) only feeds a
synthetic `meta: %{time: ...}` with no method/status/duration_ms.
`logs_live_test.exs`'s fixtures construct the broadcast entry's `metadata`
map BY HAND with the already-fixed shape, bypassing `RequestLogger`/`Handler`
entirely — proving `LogsLive`'s consumption, not the pipeline's production,
of the fix.

**Why:** a "test-review recommended a fix, dev-story applied it" step in the
pipeline does not automatically mean the fix is pinned down by a test — the
recommendation was about the CODE change, not a new assertion. This is a
distinct failure mode from [[feedback_test_review_minors_not_carried_through]]
(which is about MINORs silently dropped) — here the MAJOR fix WAS applied,
just never regression-tested, in a SHARED plug (`request_logger.ex`) touched
by multiple other stories, where a later refactor could silently break it
with no CI signal.

**How to apply:** when a fix touches a shared/security-adjacent module
(`request_logger.ex`, `payload_redactor.ex`, any `:logger` handler) as a
carried-forward test-review recommendation, explicitly check whether ANY test
in the diff asserts the produced artifact's actual shape end-to-end (not just
that a downstream consumer handles a hand-built fixture correctly). If no
such test exists, flag as MAJOR regardless of how correct the manual code
trace looks — this is exactly the kind of gap that survives multiple review
cycles because "the code is right" gets confused with "the code is pinned
down."
