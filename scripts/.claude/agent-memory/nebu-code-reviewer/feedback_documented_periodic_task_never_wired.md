---
name: documented-periodic-task-never-wired
description: A cleanup/sweeper function is defined and unit-tested but never wired into any production caller, while moduledocs assert a caller that doesn't actually call it
metadata:
  type: feedback
---

A public `cleanup_expired/0`-style hygiene function was defined, unit-tested in
isolation, and documented as "Called periodically by <SomeGenServer>" — but that
GenServer's refresh path only calls the *read* function (`active_captures/0`),
never the cleanup. The only caller in the whole repo was its own test. Two moduledocs
(the manager's AND the cache's) both asserted the periodic-cleanup wiring that does
not exist.

**Why:** Story Dev Notes explicitly specified a periodic cleanup task; the dev built
the function + tests but forgot the wiring, and wrote moduledocs describing the
*intended* design as if it were real. Impact was negligible here only by luck (PK =
endpoint capped the table at ~3 rows), so nothing broke — masking the gap. Bonus trap:
had cleanup been wired into the cache GenServer's own refresh as the docs imply, it
would self-deadlock (cleanup -> notify_cache -> refresh_now -> GenServer.call(self)).

**How to apply:** When a story specifies a periodic/background task, grep for an
actual caller (Sweeper, application.ex child, GenServer handle_info) — not just the
function definition + its unit test. A `grep -rn '\.the_function' lib/` that returns
only the module itself + test files = unwired. Also cross-check that moduledoc "called
by X" claims match reality: open X and confirm it calls it. Classify as MINOR when
impact is bounded (e.g. PK caps table growth), but always flag the inaccurate moduledoc
and the latent self-deadlock if the documented wiring were followed literally.
Related: [[feedback_fix_lacks_direct_regression_test]], [[feedback_test_review_minors_not_carried_through]].
