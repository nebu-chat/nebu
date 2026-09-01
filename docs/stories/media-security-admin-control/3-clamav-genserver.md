---
story_id: 3-clamav-genserver
title: "ClamAV GenServer (TCP INSTREAM Scanner Client)"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Every file uploaded through the Matrix Client-Server API must be scanned for malware
before it is released for download (see epic `media-security-admin-control`,
"Kontext & Rationale" and the `quarantined → scanning → released|infected` state
machine). This story builds the low-level scanner client: `Nebu.Media.ClamAV`, a
GenServer that speaks the ClamAV **INSTREAM** protocol directly over `:gen_tcp` to a
`clamd` daemon, with health-check and auto-reconnect. It does **not** implement the
Oban worker that drives the state machine (that is Story 4b, `MediaScanWorker`) — this
story is the standalone scanner boundary that worker will call.

Per ADR-024 (`docs/architecture/adr/ADR-024-clamav-malware-scanner-selection.md`),
ClamAV was chosen over commercial (OPSWAT) and cloud (VirusTotal) alternatives because
it is fully self-hosted — no file content or hash ever leaves the deployment, which is
a hard DSGVO requirement for Nebu's target audience (German municipalities/public
authorities). The client uses raw `:gen_tcp` (ADR-021, "Pure Elixir" — no NIF, no
shell-out to `clamdscan`, no new TCP client dependency; `mix.exs` has no existing TCP
client library, and none is needed for a protocol this small).

**Winston-Review 3 correction (epic, inline):** the epic's first draft assumed local
disk storage (`scan_file(file_path)`). The actual, already-shipped storage pipeline
(`Nebu.Media.Storage` / `Nebu.Media.Crypto`, Story 12.x) keeps media AES-256-GCM
encrypted directly in S3/MinIO — there is no local-disk step. This story's public
function is therefore `scan_binary/1`, operating on an in-memory binary the caller
(Story 4b) has already fetched, decrypted, and decompressed. `Nebu.Media.ClamAV` never
touches a file path.

## User Story

As the Media scan pipeline (the future `MediaScanWorker`, Story 4b), I want a
supervised, reconnecting TCP client to a ClamAV daemon that scans an in-memory binary
and returns a clear clean/infected/error result, so that uploaded files can be
malware-scanned before release without the scan pipeline needing to know anything
about TCP sockets, ClamAV's wire protocol, or connection-drop recovery.

## Acceptance Criteria

1. **AC1 — Module & supervision:** `Nebu.Media.ClamAV` is a `GenServer`, registered
   under its module name, started as a child of `Nebu.Media.Supervisor` (a new child
   supervisor analogous to `Nebu.Compliance.Supervisor`), which is in turn added to
   `Nebu.Application`'s supervision tree (`media_children/0`).
2. **AC2 — Configuration:** connection address and file-size ceiling are read from
   `config :nebu, Nebu.Media.ClamAV`:
   ```elixir
   config :nebu, Nebu.Media.ClamAV,
     address: {:tcp, "127.0.0.1", 3310},   # or {:unix, "/var/run/clamav/clamd.ctl"}
     max_file_size_bytes: 100 * 1024 * 1024  # 100 MB default
   ```
   Only the `{:tcp, host, port}` shape is implemented in this story (the epic's `S`
   ceiling and Story-Sizing rules exclude a co-located unix-socket variant from this
   package — see "Dependencies" / "Dev Agent Guardrails" below); the config shape
   nonetheless accepts `{:unix, path}` as a documented, not-yet-implemented future
   option so the config key does not need to change shape later.
3. **AC3 — Public API is `scan_binary/1`, not `scan_file/1`:** `Nebu.Media.ClamAV.scan_binary(bytes)`
   accepts an in-memory binary (already decrypted/decompressed by the caller) and
   returns one of:
   - `{:ok, :clean}`
   - `{:ok, {:infected, signature}}` — `signature` is the ClamAV signature name
     string parsed out of the `stream: <name> FOUND` response line.
   - `{:error, reason}` — every failure mode (see AC6) is a tagged error tuple, never
     a raised exception.
4. **AC4 — File-size ceiling:** when `byte_size(bytes) > max_file_size_bytes`, `scan_binary/1`
   returns `{:error, :file_too_large}` **without** opening a TCP connection at all.
5. **AC5 — INSTREAM protocol framing:** bytes are sent to clamd as a sequence of
   4-byte big-endian length-prefixed chunks, each followed by that many bytes of
   payload, chunked from the in-memory binary via `:binary.part/3` (never
   `File.stream!` — there is no file). The stream is terminated by a single
   zero-length chunk (`<<0::32>>`). Chunk size is 4096 bytes (the epic's specified
   value) for all but the final (possibly shorter) chunk.
6. **AC6 — Every `:gen_tcp` failure mode returns `{:error, reason}`, never raises:**
   connect timeout, connect refused, send failure mid-stream, recv timeout, connection
   closed by peer before a response, and a malformed/unrecognized response line all
   produce a tagged `{:error, reason}` tuple. Every `:gen_tcp` call in the module has
   an explicit timeout (connect timeout and recv timeout are both configurable-or-
   sane-default, e.g. 5000 ms) — no unbounded `receive`.
7. **AC7 — Health-check:** a `Nebu.Media.ClamAV.health_check/0` (or equivalent
   telemetry-visible state) function reports whether the last known connection
   attempt to clamd succeeded. On GenServer `init/1`, an initial health probe is
   attempted; if clamd is unreachable at boot, a `Logger.warning/1` is emitted but the
   GenServer still starts successfully (does not crash the supervision tree — clamd
   may come up after Nebu, e.g. differing container start order).
8. **AC8 — Auto-reconnect after connection drop:** a scan attempt that discovers the
   socket has been closed by the peer (or a health-check ping that fails) triggers a
   reconnect on the **next** call — the GenServer does not hold a permanently-dead
   socket in its state. Reconnect uses a short backoff (does not hot-loop against a
   downed clamd); each individual `scan_binary/1` call still completes (successfully
   or with `{:error, reason}`) within its own timeout budget rather than blocking
   indefinitely on the reconnect.
9. **AC9 — No PII/content in logs:** scan-outcome logging (clean/infected/error) never
   logs the scanned binary's content — only size, outcome, and (for `:infected`) the
   signature name, consistent with the project's existing redaction discipline (cf.
   `Nebu.Web.LogStore` payload redaction conventions).

## Acceptance Tests

Tests use a fake `clamd` — a real TCP listener process started in-test with
`:gen_tcp.listen/2` (there is no Mox dependency in this project; see
`test/nebu/media/media_fakes.exs` for the existing "fake boundary" convention — for a
raw binary TCP protocol, the equivalent fake is a real socket, not a function stub).
Suggested location: `server/test/nebu/media/clamav_test.exs`, with a shared fake-clamd
helper (e.g. `test/nebu/media/clamav_fake_server.exs`, following the existing
`*_test_support.exs`/`*_fakes.exs` naming and `test_ignore_filters` registration
pattern in `mix.exs` if it is not itself an `ExUnit.Case`).

1. **`test "scan_binary/1 returns {:ok, :clean} for a clean-scan round trip"`** — fake
   clamd accepts the INSTREAM chunks and replies `stream: OK\0`; asserts the exact
   return value and that the fake received the full binary reassembled correctly.
2. **`test "scan_binary/1 returns {:ok, {:infected, signature}} when clamd flags a signature"`**
   — fake clamd replies `stream: Eicar-Test-Signature FOUND\0`; asserts
   `{:ok, {:infected, "Eicar-Test-Signature"}}`.
3. **`test "scan_binary/1 returns {:error, :file_too_large} without connecting"`** —
   binary larger than configured `max_file_size_bytes`; asserts no TCP connection is
   attempted (e.g. fake listener's accept count stays 0).
4. **`test "scan_binary/1 returns {:error, reason} on connect refused"`** — point config
   at a port nothing is listening on; asserts a tagged error, not an exception.
5. **`test "scan_binary/1 returns {:error, reason} on recv timeout"`** — fake clamd
   accepts the stream but never replies; asserts the call returns (does not hang)
   within the configured timeout with a tagged error.
6. **`test "scan_binary/1 returns {:error, reason} on malformed clamd response"`** —
   fake clamd replies with an unrecognized line; asserts a tagged error, not a crash
   or a raised `MatchError`/`FunctionClauseError` propagating to the caller.
7. **`test "connection drop triggers reconnect on the next scan_binary/1 call"`** —
   fake clamd accepts one scan, then closes the socket; a subsequent `scan_binary/1`
   call succeeds against a fresh accept on the fake listener (GenServer reconnected
   rather than reusing the dead socket / returning a stale-socket error forever).
8. **`test "health_check/0 reflects unreachable clamd at init"`** — GenServer started
   with config pointing at a closed port; asserts `health_check/0` (or equivalent)
   reports the unhealthy state and that `init/1` still returned `{:ok, state}` (the
   process is alive, not crashed) — i.e. a `Logger.warning/1` was emitted rather than
   the GenServer failing to start.
9. **`test "INSTREAM chunk framing uses 4-byte big-endian length prefix, 4096-byte chunks, zero-length terminator"`**
   — asserts on the raw bytes the fake listener received: each chunk is preceded by
   `<<byte_size(chunk)::32-big>>`, all chunks except the last are exactly 4096 bytes,
   and the stream ends with `<<0::32>>`.

## Technical Requirements

### Module & state shape

```elixir
defmodule Nebu.Media.ClamAV do
  use GenServer

  # state: %{
  #   address: {:tcp, host :: String.t(), port :: non_neg_integer()},
  #   max_file_size_bytes: pos_integer(),
  #   socket: :gen_tcp.socket() | nil,   # nil when disconnected
  #   healthy: boolean()
  # }
end
```

- `start_link/1` reads config via `Application.get_env(:nebu, Nebu.Media.ClamAV)`,
  registers under `__MODULE__` (single named process — one clamd connection per
  node, matching the epic's "S" sizing; no connection pool in this story).
- `scan_binary/1` is a `GenServer.call/3` with an explicit timeout (the call timeout
  must exceed the internal `:gen_tcp` recv timeout, so the GenServer call itself
  never times out before the internal TCP operation has a chance to return its own
  tagged error).
- Socket management: lazily connect on first use (and on health-check), close and
  clear `state.socket` on any detected error/drop so the next call reconnects
  (AC8). No persistent-reconnect-loop process is required for this story's S-ceiling
  scope — reconnect-on-next-use is sufficient and matches the epic's "Auto-Reconnect
  nach Connection-Drop" wording, which does not mandate a background reconnect
  timer.

### Supervision

- New file `server/lib/nebu/media/supervisor.ex`, `Nebu.Media.Supervisor` — a plain
  child `Supervisor` (not an OTP application, per ADR-019), modeled directly on
  `server/lib/nebu/compliance/supervisor.ex`:
  ```elixir
  defmodule Nebu.Media.Supervisor do
    use Supervisor
    def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
    @impl true
    def init(:ok) do
      Supervisor.init([Nebu.Media.ClamAV], strategy: :one_for_one)
    end
  end
  ```
- Wire into `server/lib/nebu/application.ex`'s existing `media_children/0` (which
  currently only conditionally starts `{Finch, name: Nebu.Media.Finch}`), gated the
  same way other DB-less-unit-run-sensitive children are gated elsewhere in that
  file — e.g. behind a `config :nebu_http, :start_clamav_client` flag defaulting to
  `true`, set to `false` in `config/test.exs` so pure-unit runs (no clamd container
  available) do not attempt a real connection at boot. Follow the exact pattern of
  `jwks_cache_children/0` / `admin_children/0` (boolean app-env gate, empty list in
  test).

### TCP client

- `:gen_tcp` directly (Erlang/OTP stdlib) — per ADR-021 and ADR-024, no NIF, no
  external TCP client dependency. `mix.exs` has no existing raw-TCP-client
  dependency (`hackney`/`finch` are HTTP clients, not applicable), confirming
  `:gen_tcp` is the correct and only reasonable choice here.
- Socket options: `[:binary, packet: :raw, active: false]` — synchronous
  `:gen_tcp.recv/3` with an explicit timeout, matching AC6's "no unbounded receive."

### Connection config

- Dev-stack default: `address: {:tcp, "clamav", 3310}` (Docker Compose service name
  `clamav` on the default network — see "File List" below; no clamd service exists in
  `docker-compose.yml` today, this story adds it). Production/other environments
  configure host/port via `config/runtime.exs` in the same style as other
  `config :nebu, ...` runtime-configurable keys in that file.
- `max_file_size_bytes` default `100 * 1024 * 1024` (100 MB), matching the epic's
  Story 3 AC and cross-referenced in the epic's Story 9 policy-settings notes
  (`max_file_size_bytes` — admin-configurable ClamAV scan ceiling, epic line ~926);
  this story only needs the static app-config default, the admin-configurable
  override is out of scope here (Story 9).

### INSTREAM protocol framing detail

Per the ClamAV clamd protocol (`INSTREAM` command):

1. Send `zINSTREAM\0` (the `z`-prefixed command form, null-terminated, tells clamd to
   null-terminate its own reply so the client can read it without needing a
   line-terminator scan).
2. For each 4096-byte (or shorter, for the final one) slice of the binary: send
   `<<byte_size(chunk)::32-big, chunk::binary>>`.
3. After the last chunk, send the zero-length terminator: `<<0::32>>`.
4. Read the reply (`:gen_tcp.recv/3` with timeout) — one of:
   - `"stream: OK\0"` → `{:ok, :clean}`
   - `"stream: <signature> FOUND\0"` → parse `<signature>` → `{:ok, {:infected, signature}}`
   - `"stream: <error message> ERROR\0"` or anything else unrecognized →
     `{:error, {:clamd_error, message}}`
   - recv timeout / closed → `{:error, :timeout}` / `{:error, :connection_closed}`

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/media/clamav.ex` | ADD | `Nebu.Media.ClamAV` GenServer — INSTREAM TCP client, health-check, reconnect-on-next-use |
| `server/lib/nebu/media/supervisor.ex` | ADD | `Nebu.Media.Supervisor` child supervisor, modeled on `Nebu.Compliance.Supervisor` |
| `server/lib/nebu/application.ex` | UPDATE | `media_children/0` starts `Nebu.Media.Supervisor` behind a `config :nebu_http, :start_clamav_client` gate (default true, false in test) |
| `server/config/config.exs` (or equivalent) | UPDATE | Add `config :nebu, Nebu.Media.ClamAV, address: ..., max_file_size_bytes: ...` default |
| `server/config/test.exs` | UPDATE | `config :nebu_http, start_clamav_client: false` |
| `server/config/runtime.exs` | UPDATE | Production/env-var-driven `Nebu.Media.ClamAV` host/port, following the existing runtime-config pattern for other `config :nebu, ...` keys |
| `docker-compose.yml` | UPDATE | Add a `clamav` service (e.g. `clamav/clamav:stable`) to the dev stack (`make dev` — server + postgres + dex + minio + **clamav**), with a healthcheck and freshclam signature updates running as the image's built-in sidecar process (the standard `clamav/clamav` image runs both `clamd` and `freshclam` in one container by default — no separate sidecar container is required unless the dev agent finds the default image's freshclam cadence unsuitable, in which case a documented follow-up, not scope creep in this story, is the right place for a split image) |
| `server/test/nebu/media/clamav_test.exs` | ADD | ExUnit tests, Acceptance Tests above |
| `server/test/nebu/media/clamav_fake_server.exs` | ADD | Fake-clamd `:gen_tcp.listen/2`-based test helper, registered in `mix.exs`'s `test_ignore_filters` if it is not itself a `Case` module |

## Dev Agent Guardrails

### Do Not Change

- `Nebu.Media.Storage` / `Nebu.Media.Crypto` (Story 12.x, already shipped) — this
  story only calls into a caller's already-decrypted binary; it does not touch how
  bytes are fetched from or written to S3/MinIO.
- Do not add a Mox dependency or any mocking library — the project's established
  convention (see `test/nebu/media/media_fakes.exs`) is function-backed fakes for
  simple boundaries, or (for a raw-socket protocol like this one) a real
  `:gen_tcp.listen/2` fake server in the test process. Stay consistent with that.
- Do not implement the `{:unix, path}` socket variant in this story — the config
  shape documents it as a future option (AC2), but implementing unix-socket support
  is not required to satisfy this story's ACs and would exceed the epic's declared
  "S" sizing for Story 3 (see epic's Story-Sizing table — Story 3 is explicitly
  "unverändert", i.e. not split, meaning its scope is deliberately narrow).
- Do not implement `scan_file/1` or accept a file path anywhere in this module's
  public API. `scan_binary/1` operates **exclusively** on an in-memory binary —
  post-decrypt-and-decompress data the caller already holds in memory (either
  freshly received on upload, pre-storage, or fetched-and-decrypted from S3 for a
  re-scan). This is the corrected contract from the epic's Winston-Review 3; do not
  reintroduce a disk-path assumption.
- Do not build the Oban worker, state-machine transitions, or any
  `media_files`/`media_scan_stats` DB writes in this story — that is Story 4b
  (`MediaScanWorker`), which is a *consumer* of `scan_binary/1`, not part of this
  story's scope.
- Do not add connection pooling / multiple concurrent clamd connections — a single
  named GenServer process serializing scan calls is the epic's intended scope for
  this "S" story.

## Dependencies

None required from other stories in this epic — this story is standalone and can be
built first (the epic's dependency notes confirm: "Abhängigkeiten: keine"). Story 4b
(`MediaScanWorker`, the async Oban scan worker) depends on this story: it will call
`Nebu.Media.ClamAV.scan_binary/1` with the binary it has already fetched from
`Nebu.Media.Storage` and decrypted/decompressed via `Nebu.Media.Crypto`, and will
translate this module's `{:ok, :clean}` / `{:ok, {:infected, signature}}` /
`{:error, reason}` return values into `media_files` state transitions
(`scanning → released` / `scanning → infected` / `scanning → quarantined`
retry-with-backoff per the epic's state machine).
