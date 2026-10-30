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

# oauth-broker/storage-test-pinned-target: the pinned-request tests drive a request recorder that listens on a
# NON-loopback interface address (the SSRF guard blocks 127.0.0.0/8 unconditionally, so the "checked" address of a test can
# never be loopback). Without such an address (a laptop without network, a sandbox) those tests (tag :needs_iface_ip) are
# excluded locally; in CI (`CI` set) that must NOT happen silently: the coverage of the DNS-rebinding pin would vanish.
Code.require_file("nebu/media/storage_pinned_target_support.exs", __DIR__)

if is_nil(Nebu.Media.PinnedTargetTestSupport.local_ip()) do
  if System.get_env("CI") not in [nil, ""] do
    raise "CI is set but this host has no non-loopback IPv4 interface address: the storage-test-pinned-target " <>
            "tests (:needs_iface_ip) cannot run and would silently be skipped. Run the unit job in a container with a network interface."
  end

  IO.puts(
    :stderr,
    "[test_helper] no non-loopback IPv4 interface address: excluding :needs_iface_ip tests (storage-test-pinned-target). " <>
      "They are mandatory in CI."
  )

  ExUnit.configure(exclude: [:needs_iface_ip | Keyword.get(ExUnit.configuration(), :exclude, [])])
end

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

# oauth-broker/oauth-metadata-dcr-admin-approval: shared helpers (config seam, rate-limit
# isolation, DCR request builders, RFC 7591 error assertions) for server/test/nebu/oauth/*.
Code.require_file("nebu/oauth/oauth_test_support.exs", __DIR__)

# oauth-broker/moderation-routes-atomic-ban: shared helpers (users, rooms, kick / ban / unban requests, the barrier race, database probes,
# the sync client) of the real-database moderation suites. Loaded once; every function is `def` (no unused private helper per suite).
Code.require_file("nebu/matrix/moderation_test_support.exs", __DIR__)

# oauth-broker/power-levels-enforcement: shared helpers (levels builders, PUT m.room.power_levels requests, database probes, the armed gap / db /
# admin hooks) of the power-level suites. Loaded once, after the moderation helpers they build on; every function is `def`.
Code.require_file("nebu/matrix/power_levels_test_support.exs", __DIR__)

# oauth-broker/state-writer-redaction: shared helpers (redaction requests, the served event by read path, the stored rows, the signature check, the armed
# db hooks) of the redaction / state-writer suites. Loaded once, after the helpers they build on; every function is `def`.
Code.require_file("nebu/matrix/redaction_test_support.exs", __DIR__)

# oauth-broker/membership-state-model: shared helpers (the AC1 scenario, member-slot assertions, statement counting, direct inserts, the armed slice /
# direct-invitee / invite-write hooks) of the member-state suites. Loaded once, after the helpers they build on; every function is `def`.
Code.require_file("nebu/matrix/membership_state_test_support.exs", __DIR__)

# oauth-broker/history-visibility-enforcement: shared helpers (hv fixtures, the read paths, leak assertions, direct inserts, the model of the rule over the stored
# rows, the armed viewer-aware db hooks) of the history-visibility suites. Loaded once, after the helpers they build on; every function is `def`.
Code.require_file("nebu/matrix/history_visibility_test_support.exs", __DIR__)

# oauth-broker/gdpr-erasure-global-data: shared helpers (the seeded world of an erasure test, row snapshots, the generic fault trigger, the
# lock-holding transactions, the contract lists) of the real-database erasure suites. Loaded once, after the OAuth helpers it builds on. The file name ends
# with `oauth_test_support.exs` on purpose: mix.exs already ignores that suffix (`test_ignore_filters`), so no mix.exs change is needed (an unlisted support file in the
# test tree makes `mix test --warnings-as-errors` exit 1 with "files do not match any of the configured :test_load_filters").
Code.require_file("nebu/compliance/user_deletion_oauth_test_support.exs", __DIR__)

# oauth-broker/sync-wakeups-cluster-wide: the two-node :peer tests (tag :cluster, sync_wakeups_cluster_test.exs) are OPT-IN. They need a distributed test node
# that exists BEFORE the application boots (a node that becomes distributed later renames node() under running Horde / :pg / ETS), so they are never part
# of the default suite and nothing here starts epmd or distribution. They are a MANUAL opt-in proof that CI does not run: in a container (epmd and the distribution
# port on 127.0.0.1, ERL_EPMD_ADDRESS=127.0.0.1), from server/: `elixir --name <node>@127.0.0.1 --cookie <random> -S mix test --only cluster` (distribution exists before the app boots).
ExUnit.configure(exclude: [:cluster | Keyword.get(ExUnit.configuration(), :exclude, [])])

# story admin-reauth-button-flow: shared helpers (the nine forms, requests with a marker, the stale / fresh assertions) of the admin_reauth_button_flow_* suites. Loaded once,
# after the OAuth helpers it builds on. The file name ends with `oauth_test_support.exs` on purpose (mix.exs ignores that suffix, see the note above).
Code.require_file("nebu/admin/reauth_button_flow_oauth_test_support.exs", __DIR__)
