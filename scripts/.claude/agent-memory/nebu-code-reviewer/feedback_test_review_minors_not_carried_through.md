---
name: feedback-test-review-minors-not-carried-through
description: MINOR findings from the pre-dev test-review gate are explicitly deferred to dev-story "to address during implementation" but in practice are often NOT fixed by the time code lands in code review -- re-check them explicitly, don't assume they were handled
metadata:
  type: feedback
---

Observed in `enhanced-logging/operational-log-store` (cycle 0 code review).
The pre-dev test-review step found 2 MAJOR + 3 MINOR gaps in the ATDD test
files. Per that step's own stated policy, the 2 MAJOR gaps were fixed
immediately (pipeline running headless, no interactive "continue" available),
but the 3 MINOR gaps were explicitly left as "logged for the dev agent to
address during implementation (not blocking)". By the time the story reached
code review, all 3 MINOR items were STILL present, verbatim, in the shipped
test files (hardcoded `Process.sleep/1` instead of an existing polling
helper in the same file; `if Process.whereis(Nebu.Repo) do ... end` DB guards
with no `:integration` tag; a wiring path tested only indirectly). The dev
agent's own Dev Agent Record did not mention having addressed them, and did
not flag them as intentionally skipped either.

**Why:** "Deferred to dev-story, not blocking" quietly becomes "never done"
unless someone explicitly re-checks. The dev agent's focus during
implementation is making ACs pass, not re-auditing test-quality MINOR notes
from an earlier pipeline step it may not even re-read.

**How to apply:** When a pre-dev test-review artifact (e.g.
`step-results/<story>/test-review-findings.md`) lists MINOR findings deferred
to dev-story, explicitly go re-check each one against the actual shipped test
files during code review — do not assume "logged for dev agent" means
"handled". If still present, they roll forward as MINOR findings in the code
review report (dev agent gets another chance to fix them there), but call out
explicitly that they are recurring/carried-over, not new — this matters for
the 3-cycle escalation rule (the same MINOR persisting across the test-review
gate AND the code-review gate is a process signal, not just a code one).

See [[project_enhanced_logging_epic]].

**Counter-example (2026-07-07, admin-sidebar-nesting cycle 0):** all 2 MAJOR + 3 MINOR
test-review findings were verifiably carried through into the final tests (full-path
Floki combinator, exact-URL step, real Tab presses, aria-current nil pin, getByRole
button check) — each fix site carries a "Test-review MINOR-n/MAJOR-n" comment, which
made the re-check trivial. Keep re-checking item-by-item, but this labeling convention
is the pattern to praise/encourage when present.
