ExUnit.start()

# Exclude :integration-tagged tests from unit runs (mix test without NEBU_DB_URL).
# Integration tests require a live PostgreSQL instance and are only run via
# make test-integration (which sets NEBU_DB_URL and starts Nebu.Repo).
ExUnit.configure(exclude: [:integration])

# media-gateway-migration: shared test support + function-backed fake boundaries
# (loaded once so every media_*_test.exs can use them without per-file requires).
Code.require_file("nebu/media/media_test_support.exs", __DIR__)
Code.require_file("nebu/media/media_fakes.exs", __DIR__)
