# Blocker found before ATDD (Step 2) — 2a-post-media-create

## What I checked (per the caller's explicit instruction)

Read the actual, already-merged `server/lib/nebu/media/state_machine.ex` (Story 1b) to
verify its "transition-creation semantics for a brand-new row" before writing tests
against it.

## Finding

`Nebu.Media.StateMachine` has **no entry point that can create a new `media_files`
row at all**, and its actor-type contract is incompatible with the story's stated
assumption.

1. **No row-creation capability.** The only public mutator is:

   ```elixir
   def transition(media_id, to_state, actor, metadata \\ %{})
   ```

   Its implementation does `SELECT state FROM media_files WHERE media_id = $1 FOR
   UPDATE` first; if the row doesn't exist (`%{rows: []}`), it rolls back with
   `{:error, :not_found}`. There is no "insert" path, no `reserve/1`, and no
   nil-pseudo-state handling anywhere in the module or its `@transitions` guard
   table (`reserved: [:quarantined]` is the map's only entry touching `:reserved`,
   and it's a *target*, never a *source* key of `nil`/absent).

   The story's Technical Requirements section explicitly anticipated a **name**
   mismatch ("If 1b's actual public function has a different name/shape (e.g.
   `transition/3` from a `nil` pseudo-state), adapt the call site accordingly") —
   but what actually exists is not a differently-named creation path, it is **no
   creation path whatsoever**. `do_create/2`'s sketched call to
   `Nebu.Media.StateMachine.reserve(%{...})` in the story has nothing to adapt to.

2. **Actor-type guard structurally rejects the story's assumed shape.** The
   module's type and guard clauses:

   ```elixir
   @type actor :: {:system, nil} | {:admin, Ecto.UUID.t()}

   def transition(_media_id, _to_state, {:system, actor_id}, _metadata) when not is_nil(actor_id) do
     {:error, :invalid_actor}
   end
   ```

   `{:system, actor_id}` with a non-nil `actor_id` is a hard reject — always. The
   story's own "Open assumption" section proposes exactly this shape for a
   user-initiated reservation: `actor_type: :system, actor_id: <uploader's Matrix
   user ID>`. That assumption is not just unconfirmed, it is **impossible** against
   1b's real contract as merged. (The Matrix user ID can still go in
   `media_files.uploader_user_id` — a separate, pre-existing column — but it cannot
   be threaded through as `media_state_transitions.actor_id` the way the story
   describes, because that column only ever holds an admin's `UUID` or `NULL`.)

3. Confirms the story's own **Dev Agent Guardrails** anticipated this class of
   problem: *"the `Nebu.Media.StateMachine` module's public contract (Story 1b) —
   this story is a consumer of both, not their owner. If the migration or module
   genuinely need a change to support this story, that is a sign the dependency
   story was underspecified — flag it rather than quietly extending 1a/1b's scope
   inside a 2a PR."* That is exactly the situation here.

## Why this blocks ATDD

Any acceptance test asserting "the injected state-machine seam was called with
`to_state: :reserved`, `uploader_id/actor_id: '@uploader:test.local'`" (story's own
Acceptance Test #1) is testing a call shape that the real module cannot accept in
production. Writing the tests now, before this is resolved, means either faking a
seam whose contract diverges from the real module (masking the gap until
integration/CI), or building tests around a design that will have to change anyway.

## Options (not deciding this myself, per your instructions)

**(a) Extend `Nebu.Media.StateMachine` in this same PR** — add a creation entry
point (e.g. `create/1` or `reserve/1`) that performs the `INSERT` + the
`media_state_transitions` row (`from_state: NULL`) atomically, matching the existing
`Repo.transaction/1` pattern. This directly contradicts the story's own "flag it,
don't extend" guardrail, but is the smallest, most natural code change — 1b is
already merged and owned by this same epic/team, not a truly external dependency.
Would also need to decide the actor-shape question: either (i) relax the guard to
allow `{:system, actor_id}` for creation only, or (ii) accept that
`media_state_transitions.actor_id` stays `NULL` for this transition and rely solely
on `media_files.uploader_user_id` for identity (simpler, arguably more consistent
with "system" meaning "no human actor was in the loop").

**(b) Treat this as a real 1b follow-up story** — pause 2a, file a short follow-up
against 1b's own epic slot (or a 1b-patch story) to add the creation capability with
its own review, then resume 2a once that lands. Cleanest separation of concerns,
costs a cycle.

**(c) Redefine 2a's actor-shape assumption instead of touching 1b's guard** — keep
`{:system, nil}` (no `actor_id` at all) for the reservation's
`media_state_transitions` row, and rely only on `media_files.uploader_user_id` for
"who reserved this" (which is already sufflicient for 2b's ownership check, the
story's stated reason AC1's `uploader_id` requirement exists). This avoids touching
the actor-type guard at all — only the row-creation gap (option a's INSERT
mechanism) still needs solving.

My recommendation, if useful: (a) combined with (c) — add one new
`Nebu.Media.StateMachine.create/1`-shaped function that performs the initial INSERT
+ transitions-row write atomically with `actor_type: :system, actor_id: NULL`
(satisfies the existing guard unchanged), and rely on `media_files.uploader_user_id`
(already a column, already required by AC1) as the identity record — avoiding any
change to the actor-type contract while still resolving the row-creation gap. But
this is a design call for you, not something I should decide unilaterally given the
story's explicit instruction not to silently extend 1b.

## RESOLVED — coordinator decision (2026-07-14)

Coordinator decided:
1. Do NOT extend `transition/4`'s actor-type guard — the `media_transition_actor_type`
   ENUM (`system|admin`) stays two-valued, tracking who changed state, not file
   ownership. Add a new genesis/creation function to `Nebu.Media.StateMachine`
   (INSERT + `media_state_transitions` row `from_state: NULL, to_state: :reserved,
   actor_type: :system, actor_id: NULL` — already-legal shape, no guard change).
2. Track uploader identity as a plain `media_files` column, separate from the
   transitions-ledger actor semantics — coordinator asked me to verify whether such
   a column already exists before assuming a new migration is needed.

**Verification result: the column already exists.** `media_files.uploader_user_id`
(`TEXT NOT NULL`, indexed via `media_files_uploader_idx`) has existed since
`000001_init.up.sql` (pre-dates this epic entirely) and is already the field the
existing synchronous `Nebu.Media.upload/1` handler populates from
`conn.assigns.current_user` (`lib/nebu/media.ex:218`). The coordinator's assumption
that it was "genuinely missing" was incorrect — **no new migration is needed** for
identity tracking. This does not contradict the plan's intent, only simplifies it
(skip migration entirely, reuse the existing column/index).

Side note (non-blocking): the story's Technical Requirements §5 claims a
"`UNIQUE (server_name, media_id)` constraint already exists from Story 1a's
migration" for collision defense-in-depth — the real constraint is stronger:
`media_id` alone is `PRIMARY KEY` on `media_files` (from `000001_init.up.sql`,
pre-1a). Functionally equivalent for collision-detection purposes (a PK violation
still yields the same `{:error, :media_id_taken}`-style signal this story needs),
just a factual inaccuracy in the story text, not a blocker.

Design going forward: new `Nebu.Media.StateMachine` genesis function performs the
`media_files` INSERT (media_id, server_name, uploader_user_id, state: 'reserved',
+ existing required columns) and the transitions-ledger row atomically in one
`Repo.transaction/1`, actor fixed to `{:system, nil}`. No schema migration in this
story. Proceeding to ATDD.
