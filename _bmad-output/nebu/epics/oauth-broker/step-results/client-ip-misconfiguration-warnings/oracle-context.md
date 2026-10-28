# Oracle gate (caught up 2026-10-14, nebu-oracle, read-only): client-ip-misconfiguration-warnings @ 6543bc4e

Verdict: PASS, no MAJOR. The story frontmatter says `matrix: false`; `classify_story.py` printed `matrix: true` only through its regex fallback (a false positive), so the gate was run afterwards.

- W1 (`plugs/client_ip.ex`): the trusted / untrusted decision, `ClientIP.resolve/3`, `store/4` and `bucket_for/1` are unchanged; the new code only logs a static, throttled WARNING (`:atomics`). No status, body, `M_LIMIT_EXCEEDED` / `retry_after_ms` or bucket change for Matrix clients.
- W2 (`workers/client_ip_check_worker.ex`, `DeviceKeyStore.address_spread/1`): an Oban background job with a read-only `SELECT count(...)` on `devices`; `GET /devices` and `last_seen_ip` unchanged.
- W3: OpenTofu `check` blocks and documentation only.
- No endpoint, errcode, status code, response format, auth or login flow, `/sync` or event semantics changed. No spec gaps, no new test duty (regression invariants: an untrusted-peer `X-Forwarded-For` request gets the same status / body as without the header; the rate-limit bucket stays the socket address; covered by `client_ip_test.exs` and `client_ip_check_worker_test.exs`).
