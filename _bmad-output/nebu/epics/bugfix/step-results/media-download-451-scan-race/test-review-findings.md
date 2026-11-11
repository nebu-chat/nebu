# Test review (pre-dev) — media-download-451-scan-race
Verdict: 0 MAJOR, 8 MINOR, 6 INFO. All ACs covered; edits to existing tests (timeout_ms=0) keep intent.
Files: server/test/nebu/media/media_download_stall_test.exs (new tests ~L657-1193), media_download_gate_test.exs, media_response_content_type_test.exs

MINOR (fix in the test files during dev-story, tests-first):
1. Flaky bound "explicit timeout_ms smaller than default" (@fast_cfg, timeout_ms=150, elapsed<235 vs default 250). Use default_stall_ms ~1500, timeout_ms=150, assert <1000.
2. AC4 timeout tests: elapsed>=200 and <500 against default 250 / max 600 — too narrow. Use default ~300, max ~5000, bound <1500 so "used max" / "used 20000" fail clearly.
3. Released-mid-window tests assert elapsed<240 vs 250ms window. Use window ~2000 and bound <1000 (early-return tests cost nothing extra).
4. Hard waits as synchronisation: AC5 Process.sleep(100), event-driven test Process.sleep(200), AC6 non-member loop trailing Process.sleep(150). Replace with bounded polling of Registry.lookup(Nebu.PubSub, topic(id)) != []; drop trailing sleep. (Process.sleep(40) in AC7 race repro is scenario timing — OK.)
5. AC6 non-member test imprecise: broadcast at ~300ms with 600ms window so the elapsed bound discriminates; add an explicit timeout_ms=N>0 non-member variant; avoid the 100ms-broadcast flake path (late immediate request would see :released -> 403 vs 451 baseline).
6. Stale names/moduledoc in pre-existing AT6 + list-shaped test ("behave like absent") — rename to "behave like timeout_ms=0 / no-stall".
7. Config boundaries untested: assert Nebu.Media.default_stall_ms() == 20_000 (and key present in config.exs); test default_stall_ms: 0 / negative as kill switch for the absent case; non-positive max_stall_ms with absent param.
8. Index-coupled generation (@endpoint_labels vs Enum.at(endpoints(), idx)) — iterate one list of {label, builder}.

INFO: no stall-path test that storage is never touched on timeout/deny; AC4 mid-window deny covers only 2 of 5 endpoints (add body byte-identity vs unknown id on stall path); legacy /_matrix/client/v1/media/v3 aliases + v3 download/{fileName} unexercised; thumbnail 413/429 don't exist (upload-only); no non-member 403-after-release test; no :quarantined->:scanning budget-not-reset test (pre-existing).

Implementation drivers (from ATDD agent): (a) "exactly one DB lookup" guard — no pre-stall current_state lookup for released/deny/unknown; reuse one read or read only when state is :quarantined/:scanning. (b) AC6: membership must be checked BEFORE stalling (today the state gate precedes membership; non-member on scanning file got 451). (c) stall must be PubSub-driven only (no polling).
