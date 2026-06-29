ExUnit.start()

# Exclude :integration-tagged tests from unit runs (mix test without NEBU_DB_URL).
# Integration tests require a live PostgreSQL instance and are only run via
# make test-integration (which sets NEBU_DB_URL and starts Nebu.Repo).
ExUnit.configure(exclude: [:integration])

# oidc-bootstrap-only-config (ADR-022): shared helper to install the OidcConfig DB
# seam (server_config source) — replaces the old :oidc_issuer/:oidc_audience env idiom.
# Loaded FIRST so support files that reference it (e.g. media_test_support.exs) see a
# defined module at compile time (avoids an undefined-function --warnings-as-errors abort).
Code.require_file("nebu/web/oidc_test_support.exs", __DIR__)

# media-gateway-migration: shared test support + function-backed fake boundaries
# (loaded once so every media_*_test.exs can use them without per-file requires).
Code.require_file("nebu/media/media_test_support.exs", __DIR__)
Code.require_file("nebu/media/media_fakes.exs", __DIR__)

# admin-room-creator-provisioning: shared no-op UserStore for the create_room/2
# creator-provisioning seam, so DB-mocked unit tests need no live Repo.
Code.require_file("nebu/matrix/event_dispatcher/create_room_test_support.exs", __DIR__)
