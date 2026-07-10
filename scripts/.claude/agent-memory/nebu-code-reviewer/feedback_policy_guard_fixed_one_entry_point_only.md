---
name: policy-guard-fixed-one-entry-point-only
description: A validation/policy guard (e.g. off-tier level rejection) gets hand-copied to each new write path as found instead of centralized, recurring across review cycles; verify centralization is complete AND identify which write paths structurally cannot need the guard
metadata:
  type: feedback
---

Recurring pattern (3 cycles in a row, trace-map-filter-reset-bugfix story): a guard that must apply
to every write site of a piece of assign state (`@active_filters` off-tier `level` rejection) was
added to one entry point per cycle instead of being centralized up front — cycle 0 fixed `mount`,
cycle 1/2 fixed `sync_filters` (separate hand-copied `Enum.reject(&level_off?/2)` line), cycle 2
reverify then found a 3rd entry point (`toggle_filter_value`) still missing it.

Cycle 3 finally centralized into one shared helper (`reject_off_tier/3`) called from all "value-adding"
write paths. Verified as genuinely fixed by: grepping every `assign(socket, :<state>, ...)` call site
in the file (not just the ones named in the fix description) and checking each one either calls the
shared helper or is structurally exempt.

**Why it matters:** when reviewing "we centralized the guard" claims, the dev agent's own list of
"three write paths" was incomplete — there were actually 4 `assign(socket, :active_filters, ...)`
sites; the 4th (`remove_filter`, which only does `List.delete`) doesn't need the guard because it can
only shrink the list, never add a value. A reviewer must independently verify this exemption reasoning
per-site, not just trust the dev agent's count of "three" write paths.

**How to apply:** whenever a fix claims to centralize a validation guard across "N write paths" to a
piece of state, grep every write site to that state field yourself (don't trust the stated count).
For each site NOT calling the shared guard, confirm explicitly why it's safe (e.g. "removal-only, can't
add a disallowed value") rather than assuming the dev agent's list was exhaustive. Also verify call-site
argument order matches the shared helper's parameter order — argument-order mismatches between a
helper's definition and its pipe-call sites are a distinct, easy-to-introduce bug when refactoring
several near-identical inline guards into one shared function. See also
[[feedback_client_server_filter_model_mismatch]] for a related client/server state-shape mismatch in
the same story.
