# Test-Review Findings — 11a-storage-config-schema-secrets

## Cycle 0 (initial review)
- MAJOR: No crash/restart test for the Nebu.Media.StorageConfig GenServer holder, unlike sibling Nebu.Media.Config (which gained one after its own prior test-review flagged the same gap). Story's File List never mentions a Supervisor equivalent. Risk: unsupervised GenServer crash permanently breaks upsert/1 until redeploy, undercutting AC7.
- MINOR: AC1 (migration) not independently DB-verified during ATDD, unlike sibling's actual up/down/up round-trip verification — because the migration file doesn't exist yet at ATDD time for this story (no scaffold existed to verify against). ACCEPTED — moves to dev-story's normal migration DoD.
- INFO x3: env-var seam design (:media_storage_env_reader) confirmed sound (real NEBU_MINIO_* wiring never runs in :test env); masked-marker format pin reasonable; AT4/AT5/AT9/AT12 security-critical assertions all verified to genuinely exercise the real Nebu.Web.SecretBox primitive, not fakes.

## Fix cycle 1 (coordinator decision: "fix")
- Added AT13 "the supervised holder restarts and repopulates its ETS cache after a kill" to server/test/nebu/media/storage_config_test.exs, mirroring config_test.exs's own crash/restart test exactly (kill + Process.monitor + wait_for_restart/2 helper).
- Updated docs/stories/media-security-admin-control/11a-storage-config-schema-secrets.md:
  - Corrected migration number 000025 -> 000024 (000023 already claimed by 9a/media_config).
  - Added required GRANT SELECT, INSERT, UPDATE, DELETE ON media_storage_config TO nebu_app; to the migration SQL (same F-1/HIGH class gap Kassandra found in 9a).
  - Added mandatory Nebu.Matrix.MigrationsGrantTest extension requirement (new describe block for 000024, down-migration no-GRANT check).
  - Added new Technical Requirements subsection: Nebu.Media.StorageConfig.Supervisor, mirroring Nebu.Media.Config.Supervisor exactly (:transient restart, raw_start_link/1 MFA, max_restarts 1000/5s) + required wiring into Nebu.Application's unconditional children list alongside Nebu.Media.Config.Supervisor.
  - Updated File List with the two new/changed files (storage_config_supervisor.ex, application.ex) and migrations_grant_test.exs update.
- Verified: 13 tests (AT1-AT13), 13 failures, all UndefinedFunctionError — RED phase confirmed clean, no compile errors, only expected undefined-module warnings.

Result: MAJOR fixed, MINOR accepted with justification. Ready to proceed to dev-story.
