# Code review (cycle 0) — Story 10b (clamav-status-freshclam-age)

Verdict: solid, ship-ready. No MAJOR/CRITICAL. All 6 verified-correct scrutiny items confirmed
(put_healthy/2 centralization, asctime parser non-raising + space-padded day, signature_info/0
reconnect-retry mirror, stale?/1 second-precision strictly->, role="status" fix well-scoped,
all guardrails respected, fake-server one-shot-close fix correct).

## MINOR
1. health_check/0 can report stale healthy:true for one ~2s poll tick at outage onset, because
   signature_info/0 leaves the socket peer-closed (clamd closes after every zVERSION reply) and
   ensure_connected/1 only probes when socket==nil, so health_check reuses the dead-but-non-nil
   socket and returns the last known value. Self-corrects within one poll interval; no AC
   violated. Root cause shared with MINOR-2.
2. changed_at churns to ~now on every healthy poll (transport_error flips healthy true->false
   on the dead-socket detection, then reconnect flips it back false->true), contradicting the
   moduledoc's "only moves on a genuine flip ... dashboard doesn't undercount" claim during
   NORMAL (connected) operation — though it IS stable during a genuine sustained outage (connect
   keeps failing, put_healthy(false) no-ops). Latent trap for 10c/10d if they read changed_at
   while healthy expecting an "up since" semantic.
3. mount/3 and every 2s tick do synchronous, network-blocking GenServer calls (TCP connect/recv
   with multi-second timeouts) against the single serializing ClamAV process — per-spec (single-
   connection guardrail mandates it) but an architectural cost: page render can block up to
   connect_timeout_ms when clamd's host is unreachable (slowest exactly when down), and each open
   dashboard adds poll load contending with in-flight scans. Reviewer: "not required for this
   story's ACs" — candidate for future async/cached-read refinement.

## INFO
- humanize_age/1 goes negative under clock skew/future build-date ("vor -1h") — cosmetic.
- stale?/1 (second-precision) and humanize_age/1 (hour-truncated display) each independently
  call DateTime.utc_now() — minor duplication, consistent in practice.
- handle_info matches the literal :refresh_clamav_status atom rather than
  ClamAVStatusIndicator.refresh_message() — consistent with WarRoomIndicator precedent, not
  worth changing.
- Test quality assessed as high (AT1 pins signature value not just type, changed_at transition
  tests pin MINOR-2's intended contract, Story 3's vacuous assert/refute upgraded to shape
  matches).

## Decision
1 root cause (MINOR-1/2) is cheaply fixable: reorder status/0 to call signature_info/0 BEFORE
health_check/0, so a just-detected dead socket (set to nil by transport_error) forces
ensure_connected/1 to actually re-probe on the subsequent health_check/0 call instead of reusing
a stale non-nil socket. MINOR-3 is an accepted architectural cost per the reviewer's own
assessment (future refinement, not required for this story) — left as-is, no code change.
