# Test review — room-account-data-and-read-markers (pre-dev)
Verdict: 2 MAJOR (tests only), 11 MINOR/INFO. AC1–AC8 covered, AC9 docs untested by design. No crash/restart test needed (Postgres store).

## MAJOR — fix the TESTS FIRST (before implementing)
- MAJOR-1: room_account_data_test.exs ~l.606-610: the DEACTIVATION test pins deletion of room account data on `deactivate_user`. Deactivation is reversible (reactivation exists), neither spec nor story AC7 requires deletion there, and a dev who correctly keeps the data would fail. REMOVE this test (keep the GDPR erasure test ~l.601-604 via `Nebu.Compliance.UserDeletion.delete_user_keys`). In the green run check that `delete_user_keys` returns {:ok,_} for a user without signing/encryption key rows; if it does not, fix the test setup so it fails only for the right reason.
- MAJOR-2: matrix_room_view_routes_test.exs ~l.166-180: the adjusted test "POST .../read_markers is routed (not the catch-all)" lost its assertions (`status == 200`, `json == %{}`) and now only has `refute_catch_all`. Add a concrete assertion for the new contract: unknown room/event is refused like /receipt: `assert conn.status in [400, 403, 404]` AND it is not the catch-all body.

## MINOR (apply in the same test pass)
- MINOR-1: per-user cap test (~l.449-474) does up to 5000 sequential calls: add `@tag timeout: 300_000` so a missing cap fails with the clear assertion instead of a 60 s ExUnit timeout.
- MINOR-2: cap errcode set too narrow (~l.468-469): also allow `M_RESOURCE_LIMIT_EXCEEDED` (and status 507).
- MINOR-3: persistence check via information_schema (~l.141-161, 415-435, erasure setup ~l.597) requires exactly ONE matching row across all tables with user_id/room_id/type: a legitimate design with an extra change-log table (also user_id/room_id/type) yields 2 rows. Loosen: select the table whose row contains the exact body (`body in Map.values(row)`), count per that table; add a comment about future tables (room tags) with a `type` column.
- MINOR-5/INFO: the no-DB guard tests (~l.205-210) require the 405/403/400 type/authorization checks BEFORE any room/membership lookup: acceptable (no leak) — keep but document in a comment.
- MINOR-6 optional: non-member vs unknown-room parity compares status+errcode only; fine.
- MINOR-9: confirm no compile warnings (`mix test --warnings-as-errors`; CI uses it) — unused default args etc.
- MINOR-11 optional: read_markers `m.read` parity checks the read_receipts row but not the receipt fan-out / ephemeral receipt event in /sync; add if cheap.
- INFO: no real restart test (fresh-process read is the substitute); 413 test relies on the JSON body plug limit (1_000_000) — dev must map RequestTooLargeError to 413 M_TOO_LARGE for this route (plausible).

## Open decisions for the dev (document in Dev Notes)
- non-member write: same status+errcode as an unknown room (403 or 404, dev's choice, no leak);
- cap default < 5000 rows, errcode from {M_LIMIT_EXCEEDED, M_RESOURCE_LIMIT_EXCEEDED, M_TOO_LARGE, M_FORBIDDEN};
- GDPR erasure deletes room account data (delete_user_keys path); deactivation keeps it; side finding: GLOBAL account_data rows are not deleted on erasure either (own privacy bugfix; only note it).
