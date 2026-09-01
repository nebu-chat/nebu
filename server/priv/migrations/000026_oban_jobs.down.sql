-- oban_jobs / oban_peers down-migration: drop both tables, then the enum
-- type. IF EXISTS guards added (code-review MINOR fix, 2026-07-14) for
-- symmetry with the up-migration's own IF NOT EXISTS guard on the enum, so a
-- re-run against a partially-applied migration doesn't error.
DROP TABLE IF EXISTS oban_peers;
DROP TABLE IF EXISTS oban_jobs;
DROP TYPE IF EXISTS oban_job_state;
