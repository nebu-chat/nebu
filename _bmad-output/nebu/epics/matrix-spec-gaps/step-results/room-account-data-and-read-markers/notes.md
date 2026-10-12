# Notes (room-account-data-and-read-markers)
- Open decisions from ATDD: non-member write 403 vs 404 (tests only require same status+errcode as an unknown room); cap value/errcode (default < 5000 rows); whether DEACTIVATION (possibly reversible) should delete room account data — tests currently pin erasure (`Nebu.Compliance.UserDeletion.delete_user_keys`) AND deactivation; test review should decide whether the deactivation pin is justified.
- Side finding (NOT in scope, own privacy bugfix): GLOBAL `account_data` rows are not deleted anywhere (not on GDPR erasure either).
- Known (NOT in scope): GLOBAL AccountDataStore `changed` flag is consumed per USER, a second device can miss a change (reproduce: two devices, A syncs incrementally first, B never sees the change).
- Test caveat: bodies in tests are compact single-key JSON (`{"unread":true}`), the global store re-encodes via Jason (key order lost); room store must store the body verbatim as TEXT.
- Compile warning (unused default arg) in room_account_data_test.exs may remain: re-check with --warnings-as-errors before CI (CI runs `mix test --warnings-as-errors`).
