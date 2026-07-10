---
name: feedback-redaction-wiring-gap
description: When reviewing redaction/logging modules, verify the redaction helper is actually invoked on the real data path, not just unit-tested in isolation
metadata:
  type: feedback
---

In Nebu's `enhanced-logging` epic, redaction/logging code has repeatedly shown a
specific failure mode: a redaction capability exists and is unit-tested directly
against the helper module (e.g. `PayloadRedactor.redact_payload/1` called with a
synthetic query-string or headers-map), but the calling code
(`Nebu.Web.Plugs.RequestLogger`) never actually constructs/passes that shape of
data in production — so the capability is dead code and the corresponding
Oracle/AC "MUST" requirement is not really satisfied end-to-end, even though the
isolated unit test passes and gives false confidence.

Concrete instances seen in `matrix-payload-debug-logging`:
- CI-gate cycle 1: top-level `token` field (m.login.token) not in the credential
  key list at all — caught only by a real HTTP round-trip test, not the unit
  tests.
- CI-gate cycle 2: Ecto's default query logger leaked bound params (tokens) at
  :debug — a cross-cutting leak vector entirely outside the redaction module,
  only found via full integration run, not unit tests.
- Code-review cycle 0 (this review): `PayloadRedactor.redact_string/1`'s
  deprecated `?access_token=` query-param handling, and the `credential_key?/1`
  "authorization"-as-map-key branch, are both exercised only by direct unit
  tests passing a synthetic string/map straight to `redact_payload/1` — but
  `RequestLogger` never logs `conn.query_string` anywhere, and handles the
  `Authorization` header via its own separate `redact_auth_header/1`, not via
  `PayloadRedactor` at all. Both capabilities are unreachable from the real
  request path.

**Why:** This class of bug is invisible to `mix test` (unit tests on the helper
pass) and only surfaces via full HTTP-level integration tests or careful manual
tracing of "what does the caller actually pass in" — exactly the kind of gap
the CI gate and code review are supposed to catch before Kassandra's SEC gate.

**How to apply:** For every redaction/logging story, don't just read the helper
module and its unit tests — trace backwards from the plug/caller to confirm
every Oracle MUST-listed field/pattern (query params, headers, specific field
names like `new_password`) is actually captured and piped through the redactor
in the real request/response path. If a helper's capability isn't reachable
from any real caller, flag it (MAJOR if it corresponds to an Oracle MUST,
otherwise MINOR dead-code/DRY finding). Also cross-check Oracle's exact MUST
field lists (e.g. credential key lists) against the implementation's literal
key list line-by-line — don't assume "password" substring coverage implies
`new_password` is covered, since these implementations tend to do exact-key
matching, not substring/fuzzy matching.

See [[project_enhanced_logging_epic]].

**Update (operational-log-store, cycle 0):** the same "cross-check Oracle's
MUST list item-by-item" discipline applies beyond credential-key lists — it
generalizes to any Oracle-provided placeholder/segment list. Oracle's
matrix-spec context for `operational-log-store` explicitly listed
`{roomId},{userId},{eventId},{roomAlias},{txnId},{stateKey},{eventType},{deviceId}`
as MUST-normalize route segments. The implementation correctly fixed
`state_key` (the one Oracle called out by name as a LAW area, with a
positional/structural match instead of a shape regex) but left `txn_id`,
`device_id`, and `event_type` on the same "does this look ID-shaped"
`^[0-9a-fA-F]{32,}$` regex fallback that fails open for realistic
non-hex-shaped values (typical txn_ids/device_ids never match it) — i.e. the
dev agent fixed the ONE item Oracle wrote prose about, but didn't re-derive
that the same "shape regex fails open" argument applies to every other
non-sigil-based item in Oracle's list too. When Oracle gives an explicit list,
verify EVERY item in the list has a working code path with a working test —
not just the one item accompanied by the longest paragraph of explanation.
