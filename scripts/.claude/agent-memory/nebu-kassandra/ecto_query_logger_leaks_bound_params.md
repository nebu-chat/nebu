---
name: ecto-query-logger-leaks-bound-params
description: Ecto's default query logger prints bound SQL parameter values verbatim at :debug — leaks any credential/token bound as a param the moment :debug is enabled anywhere; fix is log:false + a telemetry summary handler
metadata:
  type: feedback
---

Enabling `:debug` logging anywhere makes Ecto's built-in query logger print every query's BOUND PARAMETER VALUES verbatim (not just the `$1` placeholders). Any call site that binds a credential as a plain SQL param leaks it — e.g. `Nebu.Matrix.Session.MatrixSessionStore` binds opaque access/refresh tokens. This is a global, redactor-independent hole: it bypasses `PayloadRedactor` entirely (that guards only the HTTP plug), and hits EVERY query, present or future.

**Why:** This is strictly worse than the payload-plug gaps ([[redaction-wrapper-assumption]]) because it is not scoped to one plug — it is any query in the codebase. It matters specifically for a "make :debug safe to enable in prod" epic (enhanced-logging), where the whole premise is that turning on debug is safe.

**How to apply:** (a) Any epic/story whose selling point is "safe DEBUG logging" MUST set `config :nebu, Nebu.Repo, log: false` — grep for it. (b) Verify the replacement (here `Nebu.Repo.QueryTelemetry`, attached to the `[:nebu, :repo, :query]` telemetry event) logs ONLY `:source`/duration/success-classification and NEVER touches `:query` (SQL text is safe but unnecessary) or `:params` (bound values, unsafe) or the raw `Exception` from a failed `:result` (constraint messages can echo bound values). (c) Confirm `log: false` is set on EVERY configured Repo, and note the subtlety here: it was placed in runtime.exs (NEBU_DB_URL-gated), NOT config.exs, because `Application.get_env(:nebu, Nebu.Repo)` presence is the signal `Nebu.Application.repo_children/0` uses to decide whether a DB is configured — setting it unconditionally in config.exs made that key always-truthy and started DB children in plain unit runs. In enhanced-logging this was reviewed CLEAN (SEC Gate 2, 2026-07-08).
