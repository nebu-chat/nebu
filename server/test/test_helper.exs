ExUnit.start()

# media-security-admin-control/2d-download-stall-mechanism (fix-cycle 1,
# MINOR-1): eager-init the download-stall :atomics counter here too, so a unit
# run that exercises Nebu.Media.DownloadStall reaches counter_ref/0's pure
# `:persistent_term.get/1` with the key already present, regardless of whether
# Nebu.Application.start/2 ran first. Runs exactly once, sequentially, at suite
# boot (no concurrent racers) and is idempotent with the boot-time init.
Nebu.Media.DownloadStall.init_counter()

# Exclude :integration-tagged tests from unit runs (mix test without NEBU_DB_URL).
# Integration tests require a live PostgreSQL instance and are only run via
# make test-integration (which sets NEBU_DB_URL and starts Nebu.Repo).
ExUnit.configure(exclude: [:integration])

# Tests tagged :no_repo assert the DB-free unit environment (no Nebu.Repo process, no
# persisted state). They run in the unit job; in integration runs the Repo is up and other
# tests leave rows behind, so they are excluded there.
if Process.whereis(Nebu.Repo), do: ExUnit.configure(exclude: [:integration, :no_repo])

# oidc-bootstrap-only-config (ADR-022): shared helper to install the OidcConfig DB
# seam (server_config source) — replaces the old :oidc_issuer/:oidc_audience env idiom.
# Loaded FIRST so support files that reference it (e.g. media_test_support.exs) see a
# defined module at compile time (avoids an undefined-function --warnings-as-errors abort).
Code.require_file("nebu/web/oidc_test_support.exs", __DIR__)

# media-gateway-migration: shared test support + function-backed fake boundaries
# (loaded once so every media_*_test.exs can use them without per-file requires).
Code.require_file("nebu/media/media_test_support.exs", __DIR__)
Code.require_file("nebu/media/media_fakes.exs", __DIR__)

# media-security-admin-control/1b-state-machine-module: grep-based invariant
# checker (AC6) — defense-in-depth only, NOT a substitute for Story 1a's DB
# trigger/RLS (ADR-031). Loaded once so state_machine_invariant_test.exs can
# use it against both the real server/lib tree and in-memory fixture strings.
Code.require_file("nebu/media/media_mutation_invariant_support.exs", __DIR__)

# admin-room-creator-provisioning: shared no-op UserStore for the create_room/2
# creator-provisioning seam, so DB-mocked unit tests need no live Repo.
Code.require_file("nebu/matrix/event_dispatcher/create_room_test_support.exs", __DIR__)

# media-security-admin-control/3-clamav-genserver: real :gen_tcp fake clamd
# listener for clamav_test.exs (there's no function boundary to Mox-stub for
# a raw binary TCP protocol — the fake IS a socket). Loaded once so the
# helper module is available at compile time.
Code.require_file("nebu/media/clamav_fake_server.exs", __DIR__)
