# Code review cycle 0: client-ip-misconfiguration-warnings (2026-10-13)
No MAJOR / CRITICAL; 3 MINOR, 6 INFO.
- m1 UpCloud README positive-test block: spliced sentence ("...the TCP-mode frontends cannot be fixed this way and repeat both tests"): rewrite as two sentences (alb/dynamic: set `lb_real_ip_cidrs` after the negative test and repeat both tests; none/acme: cannot be fixed with this template (ap3), do not enable `oauth_enabled`); wrap long lines.
- m2 docs never say that W1 does NOT fire for the primary G3-2 topology (alb, empty `lb_real_ip_cidrs`: nginx is a trusted peer); add one sentence to the 07 bullet and the "Two aids exist" paragraphs of the READMEs / RUNBOOK: "W1 cannot fire for the alb collapse; only W2 (after 24 h of traffic, at least 5 users) and the `tofu plan` check see that case".
- m3 story Tasks unticked, status still ready.
INFO: W1 hot path / lifecycle, W2 worker + SQL, check blocks, comment-only template edits (rendered user_data changes: release note), docs/follow-ups consistent, conformance: no defects.
