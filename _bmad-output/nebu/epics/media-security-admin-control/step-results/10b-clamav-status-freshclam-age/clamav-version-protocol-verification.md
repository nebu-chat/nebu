# VERIFIED against real `clamav/clamav:stable` container (2026-07-20)

Container: nebu-clamav-1, image clamav/clamav:stable, ClamAV 1.5.3.

## Command
Sent raw `zVERSION\0` over a fresh TCP connection to port 3310 (same INSTREAM port
Story 3's Nebu.Media.ClamAV already manages).

## Reply (raw bytes, hex-dumped)
```
ClamAV 1.5.3/28065/Sun Jul 19 06:24:00 2026\0
```
- Single line, NUL-terminated (fits Story 3's existing `recv_until_null/3` unchanged —
  well under `@max_reply_bytes`).
- No trailing newline before the NUL.
- Format confirmed: `ClamAV <engine-version>/<db-version>/<build-date>`.
- Build-date format is C `asctime`-style: `%a %b %e %H:%M:%S %Y`
  (e.g. "Sun Jul 19 06:24:00 2026") — NOT ISO8601. Elixir's `DateTime`/`Calendar.ISO`
  parsing does not accept this natively; the parser needs a manual weekday/month-name
  table + regex capture (weekday is decorative/unused, month name -> number, day may be
  space-padded for single digits per asctime convention though not observed with day=19).
  Locale is fixed (English abbreviations), so no i18n handling needed.
  No explicit timezone in the reply — treat as UTC (matches freshclam's own UTC build
  timestamps) rather than assuming host-local time.

## Connection lifecycle finding (relevant to "Do Not Change" guardrail)
Piping `zVERSION\0` immediately followed by `zPING\0` on the SAME TCP connection (both
with no delay, and again with a 1s delay) produced only ONE reply (the VERSION one) —
clamd closes the connection server-side after answering a bare one-shot `z`-command; it
does NOT keep it open for a second command the way a persistent session would.

Implication for `signature_info/0`: it must use Story 3's existing
`ensure_connected/1` (connect-if-nil) before sending, exactly like `scan_binary/1` does,
and should not assume the socket is reusable immediately afterward — the following
call (whether it's another `signature_info/0`, a `health_check/0`, or a `scan_binary/1`)
will find the socket already closed by the peer and must go through the same
"reused socket found dropped -> reconnect once, retry within that call" path Story 3's
AC8 already implements for `scan_binary/1`. This is not a new problem to solve — it is
the exact same lazy-reconnect machinery Story 3 already has, extended to a new command;
do not build a separate "close after send" step, just let the existing detection do its
job on the NEXT call. No change needed to Story 3's reconnect logic itself.

## Verdict
Story 10b's Summary/AC3 assumption about the `VERSION` command and its reply shape is
CONFIRMED correct against the real dev-stack container. No AC change needed. The
asctime-style build-date format detail above should inform the parser implementation in
`signature_info/0`.
