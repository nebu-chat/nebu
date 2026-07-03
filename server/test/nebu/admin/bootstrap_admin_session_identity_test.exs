defmodule Nebu.Admin.BootstrapAdminSessionIdentityTest do
  @moduledoc """
  ATDD tests for story `fix-bootstrap-admin-session-identity` (epic `oidc-simplification`).

  ## The bug

  `Nebu.Admin.Auth.bootstrap_confirm_claim/2` mints the post-bootstrap admin session
  with a hand-built map (`sub`/`email`/`admin`/`session_exp`/`refresh_grace_exp`) that
  does NOT include `"matrix_user_id"`. `normal_callback/2` (the ordinary login path)
  instead calls `put_current_user/2`, which DOES set `"matrix_user_id"` via
  `Nebu.Matrix.UserId.from_claims/2`.

  Downstream, `RoomsController.actor_id/1` / `UsersController.actor_id/1` fall back to
  the raw `"sub"` claim value when `"matrix_user_id"` is absent — so an operator who
  creates a room via the Admin UI immediately after finishing the bootstrap wizard (no
  prior Matrix login) gets attributed with the opaque OIDC `sub`, not their canonical
  Matrix user_id (`@localpart:server`).

  ## AC1 — same session builder as normal_callback/2

  `bootstrap_confirm_claim/2` must mint the session via `put_current_user/2` (or a
  shared successor), not a second, separate map construction.

  ## AC2 — full verified claims survive to session creation

  Today only `bootstrap_sub` / `bootstrap_email` / `bootstrap_claims` (a FLATTENED
  `[[dotted_key, value], ...]` list built for the claim-picker UI, not a claims map
  usable by `UserId.from_claims/2`) are stashed in the draft. For `matrix_user_id` to
  be derivable identically to a subsequent normal login, the full verified claims map
  must be stashed as a new draft key (this test suite asserts the OBSERVABLE effect —
  correct `matrix_user_id` — not the draft key name, so the fix has latitude in
  implementation as long as the behavior holds).

  ## Session_exp behavior-change pin

  `put_current_user/2` computes `session_exp` via `session_expiry/1`, which floors by
  `claims["exp"]` when present. Today's hand-rolled bootstrap path does NOT floor by
  `claims["exp"]` — it only uses `now + admin_session_ttl_seconds`. Routing bootstrap
  through the real `put_current_user/2` with the full claims map (now including `exp`)
  is a behavior change worth pinning explicitly either way.

  ## oidc_user_id_claim cache-timing edge

  `complete_bootstrap/2` writes `oidc_user_id_claim` to `server_config` but the fix
  must ensure a NON-DEFAULT configured claim, chosen during THIS SAME bootstrap flow,
  is actually honoured by the `matrix_user_id` computed in the mint that follows —
  proving the OidcClaimCache is not serving a stale/default value at that exact moment.

  ## Seams (ADR-018, no live Repo in the unit suite)

    * `:admin_bootstrap_store` — the same injectable draft/config dispatcher
      `Nebu.Admin.BootstrapLive` + `Nebu.Admin.Auth.bootstrap_completed?/0` use.
    * `:matrix, :oidc_claim_reader` + `Nebu.Matrix.OidcClaimCache.reset_for_test/0` —
      the seam `Nebu.Matrix.UserId.configured_claim/0` reads through.

  ## Crash/restart — NOT APPLICABLE

  Stateless request handler over the signed session + a DB read/write
  (Persistenz Option C). No GenServer state of its own to recover (the OidcClaimCache
  GenServer's own crash/restart semantics are covered by `oidc_claim_cache_test.exs`).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @client_id "nebu-admin"
  @client_secret "super-secret-oidc-value"

  # In-memory draft + config store backing the inline-SQL seam. Mirrors
  # bootstrap_oidc_flow_test.exs's install_store/1.
  defp install_store(overrides \\ %{}) do
    encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

    draft =
      Map.merge(
        %{
          "instance_name" => "test-nebu",
          "oidc_issuer" => @issuer,
          "oidc_client_id" => @client_id,
          "oidc_client_secret" => encrypted,
          "oidc_audience" => "nebu-audience",
          "oidc_user_id_claim" => "sub",
          "oidc_displayname_claim" => "name",
          "oidc_email_claim" => "email"
        },
        overrides
      )

    store = start_supervised!({Agent, fn -> %{draft: draft, config: %{}} end})

    dispatcher = fn
      :load_draft, [] -> {:ok, Agent.get(store, & &1.draft)}
      :put_draft, [k, v] -> Agent.update(store, &put_in(&1, [:draft, k], v)) && :ok
      :clear_draft, [] -> Agent.update(store, &%{&1 | draft: %{}}) && :ok
      :put_config, [k, v] -> Agent.update(store, &put_in(&1, [:config, k], v)) && :ok
      :bootstrap_completed?, [] -> {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    store
  end

  setup do
    Nebu.Web.OidcTestSupport.configure(@issuer, @client_id)
    Application.put_env(:nebu_http, :admin_secret_at_rest, "bootstrap-identity-test-key")
    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)
      _ -> nil
    end)

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_secret_at_rest,
            :server_name,
            :admin_session_secure,
            :admin_oidc_config_reader,
            :admin_bootstrap_store,
            :admin_session_ttl_seconds
          ] do
        Application.delete_env(:nebu_http, k)
      end

      Application.delete_env(:matrix, :oidc_claim_reader)
      Nebu.Matrix.OidcClaimCache.reset_for_test()
    end)

    :ok
  end

  defp session_conn(method, path), do: conn(method, path) |> init_test_session(%{})

  # Injects the operator-configured oidc_user_id_claim via the SAME seam
  # Nebu.Matrix.UserId reads through (mirrors admin_matrix_identity_unification_test.exs).
  defp set_user_id_claim(claim) do
    Application.put_env(:matrix, :oidc_claim_reader, fn -> claim end)
    Nebu.Matrix.OidcClaimCache.reset_for_test()
  end

  # Seeds the draft the way the FIXED bootstrap_callback/2 stashes it, given a set of
  # verified token claims: bootstrap_sub/bootstrap_email/bootstrap_claims (unchanged,
  # AC4 — the claim-picker UI still needs these) PLUS bootstrap_full_claims (AC2 — the
  # full verified claims map bootstrap_confirm_claim/2 decodes and passes to
  # put_current_user/2, so matrix_user_id can be derived exactly as a subsequent normal
  # re-login would). This is a hand-simulation of bootstrap_callback/2's draft writes
  # rather than a call through the real function, so it must be kept in sync with it —
  # see bootstrap_callback/2 in server/lib/nebu/admin/auth.ex.
  defp seed_draft_from_callback(store, claims) do
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_sub"], claims["sub"]))
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_email"], claims["email"] || ""))

    discovered =
      Auth.extract_discovered_claims(claims)
      |> Enum.map(fn {k, v} -> [k, v] end)

    Agent.update(store, &put_in(&1, [:draft, "bootstrap_claims"], Jason.encode!(discovered)))
    Agent.update(store, &put_in(&1, [:draft, "bootstrap_full_claims"], Jason.encode!(claims)))
  end

  # scope-admin-claim-to-path (code-review MAJOR M1 fix): a claim path is now mandatory
  # on bootstrap completion — bootstrap_confirm_claim/2 rejects a bare "admin_group_claim"
  # param with no path. Every call site in this file stashes its discovered claims under
  # "groups" (seed_draft_from_callback/2 and the hand-seeded drafts below all use
  # `"groups" => [...]`), so the path is hardcoded to match here.
  defp confirm(claim) do
    session_conn(:post, "/admin/bootstrap/select-claim")
    |> Auth.bootstrap_confirm_claim(%{
      "admin_group_claim_choice" => Jason.encode!(%{"value" => claim, "path" => "groups"})
    })
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — bootstrap-completion mints the session via the SAME path as
  # normal_callback/2 (put_current_user/2), not a second hand-rolled map.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1: bootstrap_confirm_claim/2 uses the same session builder as normal_callback/2" do
    test "the minted session contains matrix_user_id (present on the normal-login path today)" do
      store = install_store()

      seed_draft_from_callback(store, %{
        "sub" => "abc-123",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"]
      })

      conn = confirm("instance_admin")

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/dashboard"]

      user = get_session(conn, "current_user")

      refute is_nil(user), "a session must have been minted"

      assert is_binary(user["matrix_user_id"]) and user["matrix_user_id"] != "",
             "bootstrap_confirm_claim/2 must set matrix_user_id (via the same builder " <>
               "normal_callback/2 uses) — got user map: #{inspect(user)}"
    end

    test "matrix_user_id after bootstrap equals Nebu.Matrix.UserId.from_claims/2 for the same claims" do
      store = install_store()

      claims = %{
        "sub" => "abc-123",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"]
      }

      seed_draft_from_callback(store, claims)

      conn = confirm("instance_admin")
      user = get_session(conn, "current_user")

      expected = Nebu.Matrix.UserId.from_claims(claims, "localhost")

      assert user["matrix_user_id"] == expected,
             "expected matrix_user_id #{inspect(expected)}, got #{inspect(user["matrix_user_id"])}"
    end

    test "bootstrap-minted matrix_user_id matches what a SUBSEQUENT normal re-login of the same person would produce" do
      store = install_store()

      claims = %{
        "sub" => "abc-123",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"]
      }

      seed_draft_from_callback(store, claims)

      bootstrap_conn = confirm("instance_admin")
      bootstrap_user = get_session(bootstrap_conn, "current_user")

      # A subsequent ordinary login (normal_callback/2's own session builder) for the
      # SAME verified claims.
      normal_conn = session_conn(:get, "/admin/callback") |> Auth.put_current_user(claims)
      normal_user = get_session(normal_conn, "current_user")

      assert bootstrap_user["matrix_user_id"] == normal_user["matrix_user_id"],
             "bootstrap session matrix_user_id (#{inspect(bootstrap_user["matrix_user_id"])}) must " <>
               "equal a subsequent normal-login's matrix_user_id " <>
               "(#{inspect(normal_user["matrix_user_id"])}) for the same person — SEC Gate 1(a)"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — full verified claims survive to session creation (not just sub/email)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: full verified claims (not just sub/email) are available at session-mint time" do
    test "a configured oidc_user_id_claim (e.g. preferred_username) is honoured in the bootstrap-minted matrix_user_id" do
      store = install_store()
      set_user_id_claim("preferred_username")

      claims = %{
        "sub" => "abc-123",
        "email" => "kai@example.com",
        "preferred_username" => "kai",
        "groups" => ["instance_admin"]
      }

      seed_draft_from_callback(store, claims)

      conn = confirm("instance_admin")
      user = get_session(conn, "current_user")

      assert user["matrix_user_id"] == "@kai:localhost",
             "matrix_user_id must be derived from the FULL verified claims map (including " <>
               "preferred_username), not just sub/email; got #{inspect(user["matrix_user_id"])}. " <>
               "The flattened bootstrap_claims draft stash is lossy and cannot be used to " <>
               "reconstruct a claims map for UserId.from_claims/2 — the fix must stash the " <>
               "full verified claims map separately."
    end

    test "without preferred_username configured as the claim, bootstrap falls back to sub-derived localpart (baseline sanity)" do
      store = install_store()
      set_user_id_claim(nil)

      claims = %{"sub" => "abc-123", "email" => "kai@example.com", "groups" => ["instance_admin"]}
      seed_draft_from_callback(store, claims)

      conn = confirm("instance_admin")
      user = get_session(conn, "current_user")

      assert user["matrix_user_id"] == "@abc-123:localhost"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 is covered in admin_create_room_test.exs (room-creator regression,
  # driven through the real RoomsController + Auth.fetch_current_user plug).
  # ══════════════════════════════════════════════════════════════════════════

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — existing bootstrap assertions remain valid (additive fix only)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: existing sub/email/admin assertions remain valid after the fix" do
    test "sub, email and admin are still set correctly on the bootstrap-minted session" do
      store = install_store()

      seed_draft_from_callback(store, %{
        "sub" => "kai",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"]
      })

      conn = confirm("instance_admin")
      user = get_session(conn, "current_user")

      assert user["admin"] == true
      assert user["sub"] == "kai"
      assert user["email"] == "kai@example.com"
    end

    test "a draft with no bootstrap_full_claims (e.g. legacy in-flight bootstrap) still mints a correct session via the flattened bootstrap_claims fallback" do
      store = install_store()

      # Mirrors the OLD (pre-fix) bootstrap_callback/2 draft shape: sub/email/bootstrap_claims
      # present, "bootstrap_full_claims" absent — e.g. an operator who started the bootstrap
      # wizard's OIDC callback on a pre-fix build and completes the claim-selection step after
      # an upgrade. bootstrap_confirm_claim/2 must not brick this in-flight bootstrap — it
      # reconstructs a claims map from the flattened "bootstrap_claims" stash (bare/top-level
      # keys only) and still mints a correct, matrix_user_id-bearing session from it.
      Agent.update(store, &put_in(&1, [:draft, "bootstrap_sub"], "kai"))
      Agent.update(store, &put_in(&1, [:draft, "bootstrap_email"], "kai@example.com"))

      discovered =
        Auth.extract_discovered_claims(%{"sub" => "kai", "groups" => ["instance_admin"]})
        |> Enum.map(fn {k, v} -> [k, v] end)

      Agent.update(store, &put_in(&1, [:draft, "bootstrap_claims"], Jason.encode!(discovered)))

      conn = confirm("instance_admin")
      user = get_session(conn, "current_user")

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/dashboard"]
      assert user["matrix_user_id"] == "@kai:localhost"
      assert Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))
    end

    test "a draft with NEITHER bootstrap_full_claims NOR a decodable bootstrap_claims fails safely — no session minted, no crash, bootstrap not marked complete" do
      store = install_store()

      # An inconsistent/corrupted draft: bootstrap_sub is present (so the earlier guard clause
      # doesn't short-circuit), but bootstrap_claims is missing entirely, AND no
      # bootstrap_full_claims stash exists either — neither claims source is available for
      # bootstrap_claims/1 to build a claims map from. Must fail closed: no session, no
      # completed-bootstrap flag, no crash.
      Agent.update(store, &put_in(&1, [:draft, "bootstrap_sub"], "kai"))
      Agent.update(store, &put_in(&1, [:draft, "bootstrap_email"], "kai@example.com"))

      conn = confirm("instance_admin")

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/login?error=auth_failed"]
      assert get_session(conn, "current_user") == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Session_exp behavior-change pin — floors by claims["exp"] once bootstrap
  # routes through put_current_user/2 with the full claims map (AC1 fix).
  # ══════════════════════════════════════════════════════════════════════════

  describe "session_exp pin: floors by claims[\"exp\"] once bootstrap shares put_current_user/2" do
    test "a claims map with a near-term exp caps session_exp at that exp (not now + admin_session_ttl_seconds)" do
      store = install_store()
      Application.put_env(:nebu_http, :admin_session_ttl_seconds, 8 * 3600)

      near_term_exp = System.system_time(:second) + 60

      claims = %{
        "sub" => "kai",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"],
        "exp" => near_term_exp
      }

      seed_draft_from_callback(store, claims)

      conn = confirm("instance_admin")
      user = get_session(conn, "current_user")

      assert user["session_exp"] == near_term_exp,
             "once bootstrap shares put_current_user/2 (which floors by claims[\"exp\"] via " <>
               "session_expiry/1), a near-term id-token exp must cap session_exp — got " <>
               "#{inspect(user["session_exp"])}, expected #{near_term_exp}. Today's hand-rolled " <>
               "bootstrap path ignores claims[\"exp\"] entirely (uses only " <>
               "now + admin_session_ttl_seconds), so this pins the behavior change explicitly."
    end

    test "a claims map with NO exp still caps at now + admin_session_ttl_seconds (unchanged default)" do
      store = install_store()
      Application.put_env(:nebu_http, :admin_session_ttl_seconds, 3600)

      before = System.system_time(:second)

      claims = %{"sub" => "kai", "email" => "kai@example.com", "groups" => ["instance_admin"]}
      seed_draft_from_callback(store, claims)

      conn = confirm("instance_admin")
      user = get_session(conn, "current_user")

      afterw = System.system_time(:second)

      assert user["session_exp"] >= before + 3600
      assert user["session_exp"] <= afterw + 3600
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # oidc_user_id_claim cache-timing edge: a NON-DEFAULT claim configured during
  # THIS SAME bootstrap flow must be honoured by the matrix_user_id it mints —
  # proving OidcClaimCache is not serving a stale/default value at that moment.
  # ══════════════════════════════════════════════════════════════════════════

  describe "oidc_user_id_claim cache-timing: a claim configured in THIS bootstrap flow is honoured immediately" do
    test "oidc_user_id_claim='email' promoted by THIS bootstrap is used for matrix_user_id in the SAME flow" do
      # install_store/1 only seeds the FAKE Agent-backed draft/config dispatcher used by
      # bootstrap_store/2 — it does NOT touch Nebu.Matrix.OidcClaimCache (which reads via a
      # live Nebu.Repo query or the :matrix, :oidc_claim_reader seam, never the admin
      # bootstrap store). Asserting against Nebu.Matrix.UserId.from_claims/2 without ALSO
      # installing the claim-cache seam would make `expected` and the actual session value
      # resolve through the exact same (uninstalled) cache path — both falling back to
      # `sub` — so the assertion would pass tautologically without ever proving the "email"
      # claim was honoured. set_user_id_claim/1 installs the real seam
      # Nebu.Matrix.UserId.configured_claim/0 reads through, exactly mirroring how a live
      # instance's OidcClaimCache would be populated once complete_bootstrap/2 has written
      # oidc_user_id_claim to server_config (the two are independent stores in prod too —
      # the point of this test is that reading via the cache seam picks up the configured
      # claim, not that the admin bootstrap store and the claim cache are the same thing).
      set_user_id_claim("email")

      store = install_store(%{"oidc_user_id_claim" => "email"})

      claims = %{
        "sub" => "abc-123",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"]
      }

      seed_draft_from_callback(store, claims)

      # complete_bootstrap/2 (invoked inside bootstrap_confirm_claim/2) promotes the
      # draft's oidc_user_id_claim="email" into server_config as part of THIS request.
      conn = confirm("instance_admin")
      user = get_session(conn, "current_user")

      # Independently confirm the expected value via UserId.from_claims/2 itself
      # (the single source of truth for the sanitization rule), rather than
      # duplicating its regex as a magic string here.
      expected = Nebu.Matrix.UserId.from_claims(claims, "localhost")

      assert user["matrix_user_id"] == expected,
             "expected the email-derived localpart #{inspect(expected)}; " <>
               "got #{inspect(user["matrix_user_id"])}"

      assert user["matrix_user_id"] == "@kai_example.com:localhost"
    end
  end
end
