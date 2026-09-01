# Code Review Findings — Story `3-clamav-genserver`

**Cycle 0 · epic `media-security-admin-control`**

## Overall verdict

**CLEAN.** No CRITICAL or MAJOR findings. The implementation faithfully satisfies AC1–AC9, respects every Dev Agent Guardrail, and is well-documented. A handful of MINOR robustness/latent items and INFO notes below; none block merge. All 9 story test scenarios map to real code paths (traced each AC against the source, not just the tests).

## AC conformance summary

AC1 (module/supervision) OK · AC2 (config, `{:unix}` accepted-not-implemented) OK · AC3 (`scan_binary/1`, three shapes) OK · AC4 (size ceiling before connect) OK · AC5 (INSTREAM framing via `:binary.part`) OK · AC6 (tagged errors — see M2) · AC7 (`health_check/0` — see deviation verdict) · AC8 (reconnect-on-next-use + in-call retry) OK · AC9 (no content in logs) OK. Guardrails: no `scan_file/1`, no disk path, no Mox, no pool, no Oban/DB, `{:unix}` not implemented — all confirmed.

## Findings

**M1 — MINOR (latent AC6 violation): `call_timeout_ms/0` under-budgets the reconnect-retry path.** `clamav.ex:304-309` computes `connect_timeout + recv_timeout + 2_000`. But a reused (had_socket?) socket that hits a **recv timeout** clears the socket and triggers `retry_after_reconnect/2`, which does a *second* connect + do_scan → a *second* full `recv_timeout`. Worst-case internal work is therefore `~2 x recv_timeout + connect` (the impossible third term is excluded because a full connect_timeout means connect *failed*, so no retry recv). At shipped defaults (5000/5000) that is ~10 000 ms vs a 12 000 ms budget — **safe**. But it breaks if an operator raises `recv_timeout_ms` above `connect_timeout_ms + 2000` (realistic for 100 MB scans, e.g. recv 30 000 / connect 5000 -> internal 60 000 ms vs budget 37 000 ms), at which point `GenServer.call` exits and **raises in the caller — violating AC6's "never raises."** Fix: `2 * (connect_timeout + recv_timeout) + 2_000`. Related: retrying on a bare `:timeout` (not just a peer-close) re-sends the whole payload to an already-slow clamd (AC8 is about connection *drop*, not timeout) — consider only retrying `handle_scan_attempt` on `:connection_closed`, not `:timeout`.

**M2 — MINOR: `{:unix, path}` config raises `FunctionClauseError` instead of a tagged error.** `connect/1` (`clamav.ex:181`) only matches `{:tcp, host, port}`. AC2 says the config shape *accepts* `{:unix, path}`. If a deployment sets it, the first scan crashes the GenServer inside `handle_call` and the caller gets an exit (a raise), against AC6's spirit. Cheap, defensive fix: add `defp connect(%__MODULE__{address: {:unix, _}} = state), do: {:error, :unix_socket_not_implemented, %{state | healthy: false}}`.

**M3 — MINOR: reply read assumes the whole reply arrives in one TCP segment.** `do_scan/2` (`clamav.ex:206`) does a single `:gen_tcp.recv(socket, 0, ...)`. The `z`-prefixed protocol null-terminates the reply precisely so a client can read *until the null*. A reply split across segments would be parsed as malformed -> spurious `{:error, {:clamd_error, ...}}`. Replies are tiny (<64 B) and effectively atomic on localhost/LAN, so real-world risk is low, but a read-until-`<<0>>`-or-closed loop would be strictly correct.

**INFO — call-timeout source-of-truth split.** `init/1` merges `Application.get_env` with `start_link` opts, but `call_timeout_ms/0` reads only `Application.get_env`. Harmless today (supervisor passes `[]`; tests configure via `put_env`), but the caller-side timeout can diverge from server-side state if timeouts are ever passed as `start_link` opts.

**INFO — socket "reuse" is largely notional.** clamd closes the connection after each single INSTREAM reply, so the reused socket is typically dead on the next call and the AC8 reconnect path fires anyway. Functionally correct (test 7 proves it); the moduledoc's "reused across calls" slightly overstates reality.

**INFO — docker-compose.** `clamav` service is sound: `platform: linux/amd64` pin is justified (no arm64 manifest), `clamdcheck.sh` healthcheck + 180 s `start_period` are appropriate, no `depends_on` gate is correct given AC7's boot-tolerance. `3310:3310` host-publishing matches the existing dev-stack convention (postgres 5432, minio 9000 are published the same way) — not a regression. `NEBU_CLAMAV_HOST/PORT` runtime.exs wiring correctly mirrors the `NEBU_MINIO_ENDPOINT` pattern and is prod/dev-only; `String.to_integer` fail-fast on a bad port is consistent with existing env parsing.

**INFO — AC9 confirmed safe.** `log_scan_outcome/2` logs only `byte_size`, outcome, and (infected) the signature name. `inspect(reason)` on errors can only embed clamd-generated text (connect atoms, clamd's own ERROR message) — never the scanned binary; the payload is never in a reply. Marker test (test 9) passes. Health-check warning logs address + reason only.

## Verdict on the AC7 init-probe deviation: **MINOR (spec-wording reconciliation)**

The deviation is **defensible and correctly reasoned**, not a functional defect. The conflict with AC4's test is *genuine and unavoidable*: AC4's test starts a live fake listener and asserts `accept_count == 0`, so any synchronous eager connect-at-init would register an accept and fail it. A `handle_continue` probe does **not** escape this — `handle_continue` runs before the test's subsequent `scan_binary` call is processed, so it would still connect and bump the accept count (only a `Process.send_after` delay avoids it, and that introduces a boot race with no correctness benefit). Test 8 still passes because its `capture_log` wraps both start *and* the `health_check` call, so it does not distinguish eager-vs-lazy. No downstream consumer requires an eager boot probe: Story 4b consumes `scan_binary/1`, and boot/monitoring observability is available via `health_check/0` and the `clamav` container's own healthcheck. It is only a literal-wording gap in AC7 ("on init/1 an initial health probe is attempted"). **Recommendation:** update AC7's wording to "lazy on first health-check/scan" rather than change the code. Not MAJOR.

---

**CLEAN (0 MAJOR/CRITICAL, 3 MINOR)** — M1 latent AC6 timeout-budget under-count on the retry path (fix `call_timeout_ms/0`), M2 `{:unix}` FunctionClauseError, M3 single-segment reply read; AC7 init-probe deviation = MINOR wording gap, accept code as-is.

---

## RESOLUTION (cycle 1, same day)

All 3 MINOR findings fixed in `server/lib/nebu/media/clamav.ex` (only this file touched):

- **M1 → RESOLVED:** `call_timeout_ms/0` now computes `2 * (connect_timeout + recv_timeout) + 2_000`, covering two full connect+recv cycles (initial attempt + reconnect-retry). The reconnect-retry guard in `handle_scan_attempt/3` was narrowed to fire only on `:connection_closed` (not a bare `:timeout`) for a reused socket, avoiding a doubled wait against an already-slow-but-connected clamd.
- **M2 → RESOLVED:** added a `connect/1` clause matching `{:unix, _path}` that returns `{:error, :unix_socket_not_implemented, state}` instead of crashing with `FunctionClauseError`. Clause ordering vs. the existing `{:tcp, host, port}` clause is safe (structurally disjoint tuples).
- **M3 → RESOLVED:** added `recv_until_null/3`, looping over `:gen_tcp.recv/3` (each call keeping the configured per-call timeout, not summed) until a null byte appears in the accumulated buffer. A partial-but-nonempty buffer on timeout/close is treated as the complete reply (falls through to `parse_reply/1`, which safely classifies anything unrecognized as `{:error, {:clamd_error, line}}`); an empty buffer on timeout/close still surfaces a genuine `{:error, :timeout}` / `{:error, :connection_closed}`.

Independently re-verified (fresh-context review, cycle 1): all three fixes confirmed correct via direct code trace (including a stress-case timeout budget check at 5000/30000 ms) and re-run of the full test suite — `clamav_test.exs` 10/10 passed, full unit suite 1646 passed/4 skipped/0 failed, zero regressions.

Two new INFO-level observations (non-blocking, noted for awareness): the recv-loop now waits a full `recv_timeout_ms` on an unterminated reply before returning the malformed-response error (correctness unchanged, only slower — real clamd always null-terminates so production is unaffected); and there is no upper bound on the accumulated buffer size if a peer streamed endless non-null bytes without ever timing out (theoretical only, clamd is trusted self-hosted infrastructure with a tiny fixed reply size).

**Final status: CLEAN — 0 open MAJOR/CRITICAL, 0 open MINOR. Proceeding to security-review.**
