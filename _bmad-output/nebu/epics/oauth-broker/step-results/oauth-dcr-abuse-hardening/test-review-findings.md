# Test review (pre-dev) oauth-dcr-abuse-hardening: 0 MAJOR, 10 MINOR, 6 INFO. All AC1-AC15 covered; security semantics genuinely asserted.
Dev agent: fix these in the staged tests as part of the work:
M1 oauth_bulk_remove_test.exs:229-246 (AC8.5) concurrency test seeds 400 rows (< batch 500): seed >500 (e.g. 1200 with 3 callers) so batches must be disjoint (FOR UPDATE SKIP LOCKED).
M2 oauth_abuse_caps_test.exs:334-367 (AC6.1-6.3) assert the attacker's pending rows for the host are still present after the legit client registers (never evict).
M3 oauth_admin_test.exs:1506-1522 (AC9.5) add a positive control: POST with a valid CSRF token succeeds while bypass is off.
M4 oauth_admin_test.exs:1168,1353 escaping tests only refute the raw string: assert the escaped form is present (&lt;b&gt;) or use a parseable payload.
M5 oauth_admin_test.exs:1493 pin one exact flash string (singular wording per AC9.4).
M6 source_key_test.exs:11,87-88 async:true but writes persistent_term via ClientIP.configure: make async:false or move the block to a sync module.
M7 reset ClientIP config by restoring ClientIP.trusted() captured before, not nil.
M8 oauth_abuse_caps_test.exs:448-449,566,569 :rand.uniform(200) source IPs -> derive deterministic/unique key from T.rand (64-hex string).
M9 oauth_abuse_caps_test.exs:578 pins an attribute name @source_login_cap that the story never defines: pin behaviour/relax regex; :230,:475-477 brittle DELETE-count regexes (comment can break).
M10 public_suffix_test.exs:170 purity regex matches doc substrings (Repository): use word boundaries / strip comments+docs first.
INFO: adr_033_test.exs:752-755,772-790 vacuous pins; bulk_remove_test.exs:36-41 register separate on_exit for :oauth_repo restore; run tsc/bddgen e2e check yourself (scratchpad e2e copy per epic-brief).
