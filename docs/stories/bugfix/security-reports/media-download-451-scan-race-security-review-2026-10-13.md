## Security Review: bugfix/media-download-451-scan-race

**Diff scope:** staged diff `git diff --staged -- server/lib server/config server/test docs`, which covers `server/lib/nebu/media.ex` (`clamped_stall_ms/1`, `clamp_stall_ms/1`, `default_stall_ms/0`, new `lookup_maybe_stalled/4`, `with_authorised_media/5`, `thumbnail/3`), `server/lib/nebu/media/download_stall.ex` (the hardened `run_wait/3`), `server/config/config.exs` (`default_stall_ms: 20_000`), the stall/gate/content-type tests, and the docs (`05-building-blocks.md`, `10-quality.md`, the story file). The unstaged `deploy/tofu/.../server.tf` change is out of scope.
**Date:** 2026-10-13
**Reviewer:** Kassandra (SEC Gate 1, story-level, `security_review: required`)
**Classification:** CLEAN (0 CRITICAL / 0 HIGH). Verdict: APPROVED. Fixing F-1 in this bugfix is strongly recommended.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | `server/lib/nebu/media/download_stall.ex:95-101,194-209` | CWE-404/CWE-772. Stall-slot release relies on `try/after` in the request process. Under Bandit HTTP/2 the request runs in a `StreamProcess` that is `start_link`ed to the connection handler. When the peer closes, the handler stops with `{:shutdown, :peer_closed}`, which kills the stream process asynchronously, so `after` never runs. The slot leaks permanently and the 500-slot ceiling eventually wedges shut node-wide. This is pre-existing (2d L-2, rated LOW and "unreachable" at the time). Its reachability is now confirmed, and the default stall makes legitimate clients trigger it too. | Make slot accounting crash-safe by construction. Key slots on process lifetime instead of `try/after`: use a duplicate-key `Registry` (register the caller, then `Registry.count_match`, unregister on over-cap), or have a supervised owner `Process.monitor` the caller and decrement on `:DOWN`. Add a regression test that kills the caller with an exit signal mid-stall and asserts the counter returns to 0. |
| 2 | MEDIUM (carried 2d M-1 / Gate-2 M-1, not new) | `server/lib/nebu/web/router/media.ex:86-95`, `client_v1_media.ex:50+`, `media.ex:689-709` | CWE-770. There is no per-IP RateLimit on download/thumbnail and no per-principal sub-cap on the global per-node pool of 500. On HTTP/1 the handler cannot see a client disconnect while blocked, so a "fire request and drop it" loop pins each slot for the full 20 s at almost no cost to the attacker. One member (meaning a member of any room) can occupy all 500 slots. Everyone else then falls back to the immediate 451, which is exactly the bug this story fixes. | Not blocking: the fallback is graceful and equals pre-story behaviour, and the attacker could already do this before the story via `timeout_ms=20000`. Recommended together with the F-1 fix, since the same Registry gives both: (a) a per-`user_id` sub-cap (e.g. 16 concurrent stalls) and (b) an inline per-IP `RateLimit` tier on download/thumbnail mirroring `upload`. |
| 3 | LOW | `download_stall.ex:152-161` + `media.ex:1152-1163` | Synchronized thundering herd. Every request stalled on one media id wakes on the same broadcast and immediately runs lookup, `member?`, S3 GET and whole-object in-memory AES-GCM decrypt at the same instant. In a big room, all online Element clients request the thumbnail right after the event arrives, so this can be ≤500 × the image size in RAM in one burst. Unbounded concurrent whole-file decrypt is a pre-existing issue; the stall concentrates it in time. | Add a small random wake-up jitter (0-500 ms) after `:resolved`, or single-flight the fetch/decrypt per `media_id`. Longer term, use a per-`media_id` stall sub-cap. |
| 4 | LOW | `media.ex:621-644`, `config/config.exs:66-84`, `admin/media_settings_controller.ex:52,146` | Operator control gap, plus a forward risk. `default_stall_ms`/`max_stall_ms` are read only from compile-time `config.exs`, which is baked into the release. The documented kill switch `default_stall_ms <= 0` therefore needs a rebuild. The admin UI's `max_stall_ms` (`Nebu.Media.Config`, bound 1 ms to 1 h) is not read by the handler, so an admin who "lowers" it has no effect. Forward risk: the planned "one-line swap" to `Config.get/0` would allow a 1 h connection hold. `clamp_stall_ms/1` does `min(n, max(0, cap))` without `is_integer(cap)`, and under Erlang term order a non-integer cap such as `"20000"` sorts above every integer, so the client value goes unclamped. | Either wire the accessors to `Nebu.Media.Config` now (and expose `default_stall_ms` there), or document that the admin field is inert. Lower the admin upper bound for `max_stall_ms` to ~60 s. Guard `is_integer(cap) and cap > 0` in `clamp_stall_ms/1` and fail to 0 otherwise. |
| 5 | INFO | `media.ex:689-709` | Timing side channel. Members stall and non-members don't. For a member, the response ends early on a broadcast outcome (infected, released, scan_failed) but only after the full window for states without a per-id broadcast (admin_blocked, user-deleted; `StateMachine` broadcasts only on `media:admin`). Status and body stay byte-identical (ADR-026 holds), and polling gives the same information. Accepted (consistent with the code-review judgement). | None required. |
| 6 | INFO | `download_stall.ex:126-134` | Log hygiene, verified clean (LAW). The new `rescue`/`catch` lines log only the exception module atom or the `kind` atom. The reason is discarded. No media_id, token, query string, or content is logged, and there is no `inspect(reason)` that could carry DB parameters. | None. |
| 7 | INFO | `media.ex:654-671` | Query parsing, verified total and fail-safe. `"1e9"` → `{1,"e9"}` → 0. `"0x10"` → 0. `" 5"` → 0. `"5 "` → 0. `"+5"`/`"0005"` → 5. Bignums → clamped to cap, with length bounded by Bandit's request-line limit. Lists and maps → 0. Malformed input never buys the default hold. | None. |
| 8 | INFO | `media.ex:1056-1075` | AuthN is evaluated once, before the stall. A token revoked or a user deactivated mid-stall can still receive bytes when the window ends (≤ `max_stall_ms`). This is normal in-flight semantics at 20 s and becomes relevant only if F-4's 1 h bound ever goes live. | Covered by the F-4 bound reduction. |
| 9 | INFO | `download_stall.ex:119,170` | Cluster-safety. The producer to consumer path uses `Phoenix.PubSub`, which nebu-conventions say is "never cluster-critical". Correctness does not depend on it (subscribe-then-recheck plus a post-wait fresh read), so a missed cross-node wake-up costs only latency (the full window). The ceiling is per node. | None for security. Note in the cluster story. |
| 10 | INFO | `download_stall.ex:170` | Topic derived from the URL `media_id` (`"media:admin"` collides with the admin broadcast topic). Not reachable: the stall is entered only for an existing `:quarantined`/`:scanning` row, whose ids are server-generated, and the receive pattern only matches the 3-tuple. | Optionally prefix the topic (`"media:id:" <> id`) if ids ever become client-chosen. |

### Detail

**Finding #1: Stall slot leaks permanently on HTTP/2 peer close [MEDIUM]**

`await/4` increments the `:atomics` counter and releases it in an `after` clause in the *calling* process (download_stall.ex:95-101). An `after` clause runs only if the process unwinds by itself. It does not run when the process dies from an exit signal sent by a linked process.

How Bandit 1.12.5 behaves (verified in `deps/`):
- HTTP/2 streams run in `Bandit.HTTP2.StreamProcess`, created with `GenServer.start_link` from the connection handler process (`deps/bandit/lib/bandit/http2/connection.ex:272`). The stream process does not trap exits (no `trap_exit` in `deps/bandit/lib`).
- On TCP close, ThousandIsland returns `{:stop, {:shutdown, :peer_closed}, ...}` (`deps/thousand_island/lib/thousand_island/handler.ex:415-416`). That is an abnormal exit reason, so the linked stream process is killed while it sits in `Task.yield/2`. The `after` clause is skipped and the counter is never decremented.
- An RST_STREAM sends a message instead (`stream.ex:114`), so it does not leak. Closing the connection does.
- I reproduced this locally: a linked parent exiting with `{:shutdown, :peer_closed}` left the counter at 1.

Reachability: Bandit sniffs the h2c prior-knowledge preface on cleartext (`initial_handler.ex:70-84`). In the stackit reference deployment with `tls_mode = "none"`, the NLB passes TCP straight through to the Bandit host port 8008 (`deploy/tofu/examples/stackit/variables.tf:133`, `cloud-init.tftpl:491`). Any h2c-speaking reverse proxy hop exposes the same path. The nginx reference config uses HTTP/1.1 upstream and is not affected.

Exploit: a member of any room uploads a large file (a long scan window) or waits for a ClamAV outage. They open an h2c connection, fire 100 streams of `GET /_matrix/client/v1/media/thumbnail/<srv>/<id>` with no `timeout_ms`, and drop the TCP connection. Doing this 5 times leaks 500 slots permanently. From then on, every stall on that node returns `:no_slot`, which means the immediate 451. That re-introduces the bug this story fixes until the node restarts.

What is new in this story: before, only opt-in clients (none of the mainstream ones) ever entered the stall. Now every client does, on download and thumbnail. On an h2 hop, ordinary users closing a tab during a 20 s thumbnail stall leak slots with no attacker involved. The node degrades quietly and nothing raises an error.

Not HIGH: there is no data exposure, the endpoint keeps answering, and the failure mode is the pre-story behaviour.

Fix: monitor- or Registry-based accounting, as described in the table. A `Registry` with `keys: :duplicate` removes entries automatically when the owning process dies for any reason, and `Registry.count_match/3` per key also provides F-2's per-user sub-cap.

**Finding #2: Global pool, no per-principal sub-cap, no RateLimit [MEDIUM, carried]**

This is the same M-1 that 2d and Gate-2 already documented and accepted (the amended `10-quality.md` row is accurate). Per sanctum rule "Epic-end MEDIUM that no story owns keeps getting re-discovered": this is its fourth independent derivation, and it is load-bearing here. What this story changes is the impact, not the attacker's capability. Exhausting the pool now cancels the bugfix for every user on the node, where before it only cancelled an opt-in optimization. Two details are not in the 10-quality text and should be added: (a) on HTTP/1, a disconnected client keeps its slot for the full window because Bandit does not observe the close while the handler is blocked; (b) F-1 turns pinning into permanent leaking on h2.

Answer to the caller's question ("REQUIRED vs accepted risk?"): it is not REQUIRED to block. The degradation is graceful and pre-story-equivalent, and the risk is formally accepted. Recommended scope: if F-1 is fixed with a Registry, the per-user sub-cap costs about one extra line and should ship with it.

**Finding #3: Release thundering herd [LOW]**

Every stalled request for one id wakes on one broadcast, and each then runs `fetch_and_decrypt/3`, which holds the whole object in memory (ciphertext plus plaintext). Thumbnail serves the original image. This is organic in large rooms. Pre-existing unbounded concurrent download memory is the root cause; the stall turns a spread-out retry pattern into a single burst.

**Finding #4: Stall window not operator-controllable at runtime; inert admin field; untyped clamp [LOW]**

See the table. The `min/2` term-order issue is latent today because the config is an integer literal. It goes live on the advertised one-line swap if `Config.get/0` ever yields a non-integer.

### Verified positives (AuthZ ordering, ADR-026, crash safety)

- **Non-member and unauthenticated requests never stall.** OidcPlug runs before the handler (401 immediately, with tests). `lookup_maybe_stalled/4` calls `member?` before `await` and returns the original row, so a non-member gets the same immediate 1c answer as `timeout_ms=0`. `member?(_, nil)` returns false. A DB error in `member?` fails closed (no stall, then 451).
- **The gate still runs before `fetch_and_decrypt`/storage on every path.** The post-wait result is a fresh `db_module().lookup`, then `download_gate`, then (only for `:released`) a fresh `member?`. Revoking membership mid-stall therefore yields 403, and a row deleted mid-stall yields 404 "Media not found". The relaxed ordering only decides whether to wait.
- **ADR-026 mapping is unchanged.** `admin_blocked`, `infected`, `deleted`, `hard_deleted` and unknown ids all return a byte-identical `404 M_NOT_FOUND "Media not found"`. Tests cover the mid-window `admin_blocked` broadcast. Non-stallable states make exactly one lookup and no subscribe. `:reserved` is not stalled. `:scan_failed` resolves to the catch-all 451.
- **Task linkage is sound.** `Task.shutdown/2` unlinks before `:brutal_kill`. The task body is fully wrapped in `try/rescue/catch`, so the task cannot crash the caller through its link. `Task.yield` returning nil or `{:exit,_}` maps to `:timeout`. The PubSub subscription is cleaned up by the Registry monitor. On normal and raise paths the slot is released (test "a failed wait still releases its slot"). The only gap is the async-exit case in F-1.
- **The 2d L-3 fix is confirmed.** `Task.await` was replaced by `Task.yield + shutdown`, and the deadline is now fixed before the recheck, so a slow DB means a 451, not a 500.
- **Atom and topic safety.** There is no `String.to_atom`, and SQL is parameterised.

### Summary

CRITICAL: 0 (block commit)
HIGH: 0 (block commit)
MEDIUM: 2 (F-1 new reachability of 2d L-2, upgraded; F-2 carried M-1). Advisory; F-1 strongly recommended in this bugfix.
LOW: 2
INFO: 6

**Verdict:** APPROVED (CLEAN)
