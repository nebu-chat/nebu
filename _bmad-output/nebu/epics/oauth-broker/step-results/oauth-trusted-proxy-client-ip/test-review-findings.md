# Test review (pre-dev) oauth-trusted-proxy-client-ip: 0 MAJOR, 7 MINOR, 9 INFO
All ACs covered; spoof/security checklist satisfied. MINORs to fix by the dev agent (tests may be adjusted):
- m-1 contract test forbids "x-forwarded-for"/"remote_ip" text in rate_limit.ex/http.ex docs while AC8.1 asks the RateLimit moduledoc to describe the rightmost-untrusted XFF element: write "forwarding header" / "direct peer" in moduledocs (or relax the scan to code only: comments/docs excluded); keep the AC8.1 pins satisfiable.
- m-2 call `ClientIP.configure(nil)` in `setup` (not only on_exit) in client_ip_test.exs and client_ip_integration_test.exs.
- m-3 add CIDR rejections: bare mapped entry `::ffff:10.0.0.5`, hex mapped `::ffff:a00:0/104`, upper-case keywords ALL/TRUE, entry with invalid UTF-8/NUL must not raise.
- m-4 log tests: filter captured lines by keywords (proxy|trusted|forwarded) before counting levels.
- m-5 add log tests for oversize (65 entries / >4096 bytes: exactly one warning, entries truncated to 64 bytes, never dumped whole); TP13 plug logs nothing per request; wrap `configure("true")` (I:233) in capture_log.
- m-6 optional integration test: login through the router with a trusted proxy writes the resolved IP to devices.last_seen_ip.
- m-7 add router-level test with duplicated x-forwarded-for header lines; invalid UTF-8 LEFT of the client (`<<0xC3,0x28>>, 203.0.113.7` must resolve to 203.0.113.7) and as an intermediate hop; the plug must never raise (`String.valid?` before charlist conversion).
INFO: i-5 use T.NoSuchRepo in the jwks bucket test and drop the blanket rescue; i-4 restore previous Logger level/env instead of hard-coded values; i-7 weak "IPv6 per full address" test -> assert via ClientIP.get/plug string for two addresses in one /64.
