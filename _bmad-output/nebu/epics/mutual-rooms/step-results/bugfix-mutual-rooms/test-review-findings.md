# Test-Review Findings — bugfix-mutual-rooms (cycle 0, pre-dev)

MAJOR M-1 (rate-limit test fixed burst-count assumption) — FIXED: replaced fixed
`1..60` loop with a dynamic probe (up to 500 attempts, early-exit on first 429),
re-verified RED for the correct reason (404-driven failures unchanged; rate-limit
test now fails with a clean "no 429 observed within 500 attempts" message, 1.1s
total runtime, no hang risk). Re-staged.

MINOR m-1 (assertions embedded in test-support helpers walk_all_pages/create_room/
invite_user/join_room rather than test bodies) — accepted as-is, mirrors existing
project convention (matrix_room_routes_test.exs), not requested to change.

INFO 1-9 — all verified as positive findings / non-issues (AC1 exclusion scenarios
concretely exercised; AC3/AC4 pagination genuinely exercises total-count-exceeds-
page-length + full-walk-no-duplicates; AC5 true-positive 200-not-404 check; AC11
adversarial forged token; AC7 whitespace/+-decoding verified against Plug source;
rate-limit test IP hygiene; rate-limit setup mirrors vetted url_preview_test.exs
pattern; no GenServer introduced; no hard waits anywhere in file).

AC coverage: 1-11 all covered with located line references; AC12 correctly left
to the suite-wide CI gate, not a per-file test.

Net: 0 MAJOR open, 1 MINOR (accepted), ready for dev-story.
