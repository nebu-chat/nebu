---
name: capture-toggle-repersists-offlist-endpoint
description: An admin toggle that re-enables persistence for an off-by-default endpoint doesn't bypass redaction (redaction is upstream of the logger handler) but converts transient logs into retained records — check redaction coverage of the chosen endpoint
metadata:
  type: feedback
---

The enhanced-logging "temporary capture" feature lets an admin flip persistence back ON for off-by-default long-polling endpoints (incl. `/_matrix/client/v3/sync`).

**Why it is NOT a redaction bypass:** In this repo redaction happens UPSTREAM in `Nebu.Web.Plugs.RequestLogger` BEFORE `Logger.*` is called. `Nebu.Web.LogStore.Handler` is a generic `:logger` handler that re-derives nothing and does no redaction (its moduledoc states this as a SECURITY LAW). So gates like `should_persist?/2` only change WHETHER an already-redacted entry is persisted, never HOW it is built. Enabling capture cannot leak more than RequestLogger already let through.

**Residual risk worth a LOW/INFO note:** the feature converts a transient, never-persisted log into a persisted + retained record for the capture window — and the endpoints chosen (sync) are the highest-sensitivity ones (message content). Safety is entirely coupled to RequestLogger field coverage, which has historically had field-coverage gaps ([[redaction_wrapper_assumption]]).

**How to apply:** When a diff changes WHAT gets persisted (not how), verify the redaction point sits upstream of the persistence gate before clearing it — then flag residual exposure of the specific endpoint whose logs newly become retained. Don't escalate to HIGH just because sync is involved; the diff doesn't add logging calls.
