# ATDD Step — documented skip-with-reasoning

## Bug scope (expanded during baseline reproduction)

Original report: `defp confirm(claim \\ "instance_admin")` at
`server/test/nebu/admin/bootstrap_admin_session_identity_test.exs:173` — unused
default value, flagged by `--warnings-as-errors`. Confirmed: 11 call sites (not 8 as
originally estimated), all pass `"instance_admin"` explicitly. Default is genuinely
dead.

**Baseline reproduction (fresh git worktree, no cached `_build`/`deps`, `elixir:1.20-alpine`,
exact CI command `mix test --warnings-as-errors`) surfaced a SECOND, independent
Nebu-authored warning** that also blocks `--warnings-as-errors`, not mentioned in the
original bug report:

```
warning: the following clause will never match:

    {:error, reason} ->

because it attempts to match on the result of:

    Task.start(fn -> ... end)

which has type:

    dynamic({:ok, pid()})

type warning found at:
└─ lib/nebu/matrix/event_dispatcher/server.ex:2941: Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning/2
```

`Task.start/1` (unlike `Task.start_link/1`) always succeeds at spawning under Elixir's
current typespec (`dynamic({:ok, pid()})`) — the `{:error, reason}` clause at line 2941
can never match. Introduced in commit `d4514af5` ("Fix auto join and claim mapping of
admin users", merged 2026-07-01, on `main` before this bug's branch point). Confirmed
via `git blame` and confirmed no other `Task.start(fn ...)` call sites exist in the file.

Both warnings independently cause `ERROR! Test suite aborted ... due to warnings while
using the --warnings-as-errors option`. Fixing only the originally-reported one would
NOT make `mix test --warnings-as-errors` exit 0 — the CI job would still fail on the
second. Both are therefore in-scope for this bug fix to satisfy the stated acceptance
bar ("mix test --warnings-as-errors exits 0 clean").

## Why no synthetic ExUnit test is being written

Both fixes are:
1. `confirm/1` test helper — removing an unreachable default parameter value. No
   caller relies on the default (verified: all 11 call sites pass an explicit arg).
   Purely a function-signature edit; zero behavioral change to any test's assertions.
2. `run_post_login_provisioning/2` — removing an unreachable `case` clause that the
   compiler proves can never execute under the current `Task.start/1` typespec. The
   `{:ok, _pid} -> :ok` branch already returns `:ok`, and the function's own trailing
   `:ok` (line 2952) is the actual fallback return value — removing the dead clause
   does not change `run_post_login_provisioning/2`'s `@spec` (`:ok`) or any observable
   return value, since `case` result is discarded either way (both branches led to the
   same fallthrough `:ok` on line 2952). No caller (`validate_token/2`,
   `bulk_import_users/2`, `/login` HTTP path) branches on this function's return value.

Elixir has no idiomatic ExUnit assertion for "the compiler emits zero warnings" — it is
a build-time/static-analysis property, not a runtime behavior. Per the user's explicit
guidance, the regression check IS `mix test --warnings-as-errors` itself: RED today
(reproduced in a clean worktree, EXIT 1, exactly these 2 own-code warnings), GREEN
after both fixes (to be confirmed in ci-gate).

No new unit test is being added. No existing test's behavior, assertions, or count of
passing tests should change as a result of either fix — this is verified in ci-gate by
diffing "Result: N passed" between the pre-fix and post-fix full-suite runs.

## Test-review recommendation

Given both fixes are provably dead-code-only removals with a compiler-verified (not
test-verified) invariant, recommend test-review agrees a dedicated failing test isn't
the right tool here and green-lights proceeding straight to dev-story.
