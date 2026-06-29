# Code Review — S1 Device registry model (cycle 0)

Verdict: PASS — no MAJOR/CRITICAL. 2 MINOR, 3 INFO. SQL injection clean, COALESCE/ON CONFLICT correct, migration idempotent, 000009 untouched, Matrix spec compliant.

## MINOR (fix this cycle):
- MINOR-1 (query_devices JOIN, device_key_store.ex query_devices/1): changed to JOIN devices+device_keys. Correct per AC3, but now silently drops any device_keys row lacking a matching devices row. The 000010 backfill + put_device_keys-upserts-first establishes the invariant, but the JOIN is load-bearing. Add defense-in-depth: keep the INNER JOIN semantics (only key-bearing devices) BUT make put_device_keys robust so the device row always precedes keys (already does), AND add a brief code comment documenting that query_devices intentionally requires a devices row (backfill guarantees it for legacy rows). A defensive option: the query could COALESCE display_name from device_keys if the devices row were ever missing — but simplest acceptable fix is a clear comment explaining the invariant + the backfill that guarantees it. Do NOT change the user-visible semantics (keyless devices still excluded).
- MINOR-2 (put_device_keys, device_key_store.ex): upsert_device + device_keys insert are two non-transactional round-trips. No functional bug (device-first ordering means only the harmless keyless state can result on a crash between them). Add a one-line comment noting the ordering rationale and that the intermediate state (device row, no keys) is the valid keyless state, so a transaction is unnecessary.

## INFO (optional / follow-up):
- INFO-1: protected.ex:328-329 has a now-stale doc comment ("a device appears once it has published keys") — GET /devices now sources from devices and lists keyless devices. Fix the comment (it is in an otherwise-unmodified file; a small comment edit is fine and improves accuracy).
- INFO-2: T3 backfill test re-runs an inline copy of the migration backfill SQL (documented). Acceptable; orphan-invariant test partially compensates.
- INFO-3: last_seen_ip plumbed through store but no caller populates it (forward scaffolding for S2). Harmless.
