# ADR-018: No Domain Model — Locality of Behavior as an Architectural Principle

## Status

Accepted - 2026-06-17

## Context

Nebu is built and maintained with LLM-assisted development (BMAD methodology). This has direct
consequences for the optimal code structure: an LLM has a finite context window and works more
effectively when relevant code is *local* — visible within a single file or a tight cluster of
files — rather than distributed across multiple abstraction layers.

Classical enterprise architectures (Repository pattern, ORM mappers, Service layer, Domain model)
maximize *reuse* and *encapsulation*. These properties are valuable for human developers in large
teams. For LLM-assisted development in a small, clearly bounded project like Nebu they are a
disadvantage: they create indirection layers that an LLM must traverse, and they hide the actual
database access behind abstractions whose implementation lives elsewhere in the context window.

## Decision

Nebu uses **no Domain Model** and **no ORM**. REST requests are translated directly to SQL.
SQL is written inline in the respective endpoint implementation file.

Concretely:

- **No `Ecto.Schema`** — no struct definitions that mirror tables
- **No `Ecto.Query` / query builder** — no programmatic query construction
- **No Repository pattern** — no centralized per-entity query collection
- **No Service layer** — no intermediary between HTTP handler and database
- **SQL as first-class** — queries live where they are executed, visible in the handler

The table structure in the schema migration files (`priv/repo/migrations/`) is the only canonical
data model. It is the ground truth for all queries.

Ecto is used **only for database migrations** via `Ecto.Migrator`. No `Ecto.Schema`, no
`Ecto.Changeset`, no `Ecto.Query` in application code (see ADR-001).

## Rationale

### Locality of Behavior

Every endpoint implementation file contains in full:

- The HTTP handler (route, method, parameter extraction)
- The access check (OIDC claims, room membership)
- The SQL (what is read or written, with what conditions)
- The HTTP response (status, body shape)

A reader — human or LLM — opens a file and sees everything that happens. No implied
conventions, no navigation to another abstraction layer.

### SQL is Self-Documenting

```sql
SELECT id, creator_id, version FROM rooms
WHERE id = $1
  AND membership_state = 'join'
```

This query communicates exactly what it does. An equivalent ORM call like
`RoomRepository.findJoinedById(id)` requires reading the repository implementation to
understand the same thing.

### Searchability as an Architectural Property

SQL duplication — the same query appearing in multiple places — is not a bug under this
strategy but a deliberate feature. It enables:

```
grep -r "FROM rooms" .
grep -r "INSERT INTO audit_log" .
```

A simple search delivers a complete overview of every place in the system that touches a
specific table — with the full context of each individual usage. A centralized query module
would hide this information: you find the definition, but not the context of its callers.

For an LLM this is even more valuable than for a human: semantic search over SQL fragments
finds all relevant locations in one step without traversing class hierarchies or interface
definitions.

### Migration SQL as Ground Truth

The table structure is written in the migration files as plain SQL. An LLM can derive correct
queries directly from a `CREATE TABLE` definition — without having to understand a mapping
between object attributes and column names. This reduces hallucination risk during code
generation.

### No Implicit Conventions

Frameworks like Spring (JPA), Rails (ActiveRecord), or Ecto (with Schema) bring implicit
conventions: magic methods, lifecycle hooks, naming conventions that determine behavior. These
conventions must be explicitly known to an LLM. Plain SQL has no conventions — it does exactly
what is written.

## Rejected Alternatives

### Ecto with Schema and Changesets

**Rejected.** `Ecto.Schema` creates an abstraction between table structure and code.
Changesets add validation logic that lives outside the handler. Both increase the depth of the
context graph without delivering value for Nebu's requirements.

### Repository Pattern (per-entity query collection)

**Rejected.** A central `Rooms` repository bundles queries but hides the call context.
`RoomRepository.findById/1` does not tell you whether the call comes from an admin endpoint, a
Matrix client endpoint, or a compliance query. The inline SQL strategy makes this context
visible.

### Query Modules as Named SQL Functions (Hybrid)

**Rejected as the standard, accepted as an exception.** Named query functions without ORM
(`{"SELECT ... FROM rooms WHERE id = $1", [id]}`) would be a compromise. They reduce
duplication but sacrifice searchability and locality. As an exception for very frequently used,
complex queries with high error risk this pattern is permitted — but not as the rule.

## Consequences

### Positive

- Every endpoint file is fully readable without external references
- SQL search across the entire codebase gives a complete per-table overview
- Migration SQL is ground truth — no mapping layer between schema and code
- BMAD agents can generate and review endpoints without a deep context graph
- No framework conventions that must be known
- Kassandra (security agent) finds all database accesses via direct SQL search

### Negative / Consciously Accepted

- **SQL duplication:** The same query may appear in multiple places. This is a deliberate
  property of this strategy, not technical debt.
- **No automatic schema mapping:** Column renames require manual search and update of all
  affected queries. Counterstrategy: prefer additive migrations over column renames.
- **No ORM-level query caching:** Caching happens explicitly (ETS) or not at all — never
  implicitly through an ORM layer.

## Guidelines for Contributors and BMAD Agents

1. **Do not introduce an ORM.** Neither `Ecto.Schema` nor a query builder.
2. **Keep SQL inline.** Do not refactor SQL into separate modules as a general rule.
3. **Duplication is not a review finding.** A code review agent must not suggest
   "Extract to Repository" for inline SQL.
4. **Use migrations as reference.** When implementing an endpoint, read the relevant
   migration first.
5. **Document exceptions.** If a query module is introduced as an exception, the reason
   must be explained in a code comment.

## Related ADRs

- [ADR-001](ADR-001-elixir-otp.md) — Elixir/OTP as Core Runtime; Ecto is used only for migrations, not for ORM
- [ADR-014](ADR-014-deployment-strategy-iac.md) — Deployment Strategy and IaC; no influence on this principle

_Source: `tmp/adr-architecture.md` by Philipp, 2026-06-17_