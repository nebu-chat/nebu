# Code Review Cycle 0 — postgres-ssl-ca-cert

## MAJOR (fixed)
M-1: CA cert file fetched to host but not mounted into server container → fixed: added `volumes:` block conditional on `fetch_postgres_ca`

## MINOR (fixed)
m-1: `?sslmode=require` in DB URLs contradicts NEBU_POSTGRES_SSL convention → removed from both URLs
m-2: CA cert fetch failure silently fell back to verify_none → added explicit WARNING to stderr
m-3: openssl -showcerts may omit root CA → documented in AC-5 manual steps (INFO, not actionable here)

## INFO (acknowledged)
i-1: scope creep in upcloud/server.tf (unrelated TLS changes) — pre-existed before this story
i-2: StackIT uses verify_none despite globally-trusted CA — matches prior behavior, not regressed
i-3: chmod 0700 /opt/nebu vs bind-mount traversal — bind mounts bypass dir traversal in Docker
