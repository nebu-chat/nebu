defmodule Nebu.OAuth.SessionLifetimeLoginTest do
  @moduledoc """
  Story `session-lifetime-setting` (epic oauth-session-and-consent), scenarios 1, 2 and 4 against the REAL database: the ceiling `matrix_sessions.session_expires_at`
  that `Nebu.Matrix.OAuthSession` stamps at login (the real OAuth flow: authorize -> IdP stub -> consent -> `/oauth2/token`), the lifetime saved through the
  REAL admin form (`POST /admin/config/session-lifetime`, runtime role, real audit writer), and the rule that a refresh never moves the ceiling.

    * 1 - no row, no env: the new session's `session_expires_at` is 8 hours after the login.
    * 2 - a saved lifetime of 2 hours applies to the NEXT login (a longer one than 8 hours too); the env value is the fallback below a saved value.
    * 4 - the session issued before the change keeps its `session_expires_at` (checked in the row, also after a refresh).

  The legacy login (`Nebu.Matrix.HttpPublic.session_expires_at/1`) reads the same accessor (checked in session_config_lifetime_test.exs and here with the
  real row). Cleanup: the row of the key is restored, the audit rows of the action are removed.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.Matrix.HttpPublic
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L

  @https "https://app.example.com/cb"
  @page "/admin/config"
  @post "/admin/config/session-lifetime"

  setup do
    # OAuth is switched on through the REAL rows (not the `:oauth_config_source` seam: the seam replaces the whole `server_config` read, so the saved lifetime
    # row would never be seen)
    T.clear_oauth_config()
    T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => T.issuer()})
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.put_env_scoped(:admin_csrf_bypass, true)
    L.clear_env_ttl!()
    L.delete_row!()
    L.clear_audit_rows!()
    L.real_seams!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      L.clear_audit_rows!()
      for k <- [:oauth_repo, :oauth_session_repo, :oauth_user_active_override], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # the admin saves the lifetime through the real form (fresh sign-in marker, strict fetch metadata)
  defp save!(value) do
    conn = S.post(@post, %{"matrix_session_ttl_seconds" => value}, @page, ago: 10)
    assert conn.status in [302, 303], "the save must be accepted, got #{conn.status}"
    conn
  end

  # a live OAuth session; the IdP stub accepts every refresh
  defp login(%{cid: cid, priv: priv}) do
    s = T.session!(cid, @https, priv)
    T.idp_refresh_ok(s.sub)
    s
  end

  defp ceiling(%{at: at}), do: T.row_by_at(at)["session_expires_at"]

  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 1 - without a saved value a login keeps the 8 hour ceiling" do
    test "no row, no env: session_expires_at is 8 hours after the login", ctx do
      assert L.row_value() == nil
      now = System.system_time(:second)
      s = login(ctx)
      L.assert_ceiling(ceiling(s), now, 28_800, 60)
      assert Nebu.Web.SessionConfig.matrix_session_ttl_seconds() == 28_800
    end

    test "no row, an env value (NEBU_MATRIX_SESSION_TTL_SECONDS): the env value is the ceiling", ctx do
      L.put_env_ttl!(14_400)
      now = System.system_time(:second)
      L.assert_ceiling(ceiling(login(ctx)), now, 14_400, 60)
    end
  end

  describe "scenario 2 - a saved lifetime applies to the next login" do
    test "2 hours saved through the admin form: the next login's session_expires_at is 2 hours after it", ctx do
      save!("7200")
      assert L.row_value() == "7200"
      now = System.system_time(:second)
      L.assert_ceiling(ceiling(login(ctx)), now, 7200, 60)
    end

    test "a lifetime longer than the default applies as well (24 hours)", ctx do
      save!("86400")
      now = System.system_time(:second)
      L.assert_ceiling(ceiling(login(ctx)), now, 86_400, 60)
    end

    test "the bounds: 1 hour and 90 days", ctx do
      for seconds <- [3600, 7_776_000] do
        save!(Integer.to_string(seconds))
        now = System.system_time(:second)
        L.assert_ceiling(ceiling(login(ctx)), now, seconds, 60)
      end
    end

    test "a saved value wins over the env value; deleting the row falls back to the env value", ctx do
      L.put_env_ttl!(14_400)
      save!("7200")
      now = System.system_time(:second)
      L.assert_ceiling(ceiling(login(ctx)), now, 7200, 60)

      L.delete_row!()
      now = System.system_time(:second)
      L.assert_ceiling(ceiling(login(ctx)), now, 14_400, 60)
    end

    test "a damaged row never breaks the login: the default (or env) ceiling is stamped", ctx do
      ExUnit.CaptureLog.capture_log(fn ->
        L.set_row!("not-a-number")
        now = System.system_time(:second)
        send(self(), {:ceiling, ceiling(login(ctx)), now})
      end)

      assert_received {:ceiling, c1, now1}
      L.assert_ceiling(c1, now1, 28_800, 60)

      ExUnit.CaptureLog.capture_log(fn ->
        L.set_row!("100")
        now = System.system_time(:second)
        send(self(), {:ceiling, ceiling(login(ctx)), now})
      end)

      assert_received {:ceiling, c2, now2}
      L.assert_ceiling(c2, now2, 28_800, 60)
    end

    test "the legacy login ceiling (HttpPublic.session_expires_at/1) follows the row too" do
      save!("7200")
      now = System.system_time(:second)
      L.assert_ceiling(HttpPublic.session_expires_at(%{"exp" => now + 10_000_000}), now, 7200)
      save!("86400")
      L.assert_ceiling(HttpPublic.session_expires_at(%{"exp" => now + 10_000_000}), now, 86_400)
    end
  end

  describe "scenario 4 - sessions issued before the change keep their ceiling" do
    test "an 8 hour session still expires at its original session_expires_at after 2 hours are saved", ctx do
      now = System.system_time(:second)
      old = login(ctx)
      before = T.row_by_at(old.at)
      assert before["revoked_at"] == nil
      L.assert_ceiling(before["session_expires_at"], now, 28_800, 60)

      save!("7200")

      after_save = T.row_by_at(old.at)
      assert after_save["session_expires_at"] == before["session_expires_at"], "the ceiling of the existing session is not rewritten"
      assert after_save["expires_at"] == before["expires_at"]
      assert after_save["revoked_at"] == nil, "the session is not revoked either"
      assert T.whoami(old.at).status == 200, "and it still works"
    end

    test "a refresh after the change copies the ceiling verbatim: neither shortened to the new lifetime nor extended", ctx do
      old = login(ctx)
      original = ceiling(old)

      save!("7200")
      body = T.refresh!(ctx.cid, old.rt)

      assert [active] = T.active_rows(old.user_id, old.device_id)
      assert active["access_token_hash"] == T.token_hash(body["access_token"])
      assert active["session_expires_at"] == original

      # and the reverse: a longer lifetime saved later does not extend a session that already exists
      save!("86400")
      body2 = T.refresh!(ctx.cid, body["refresh_token"])
      assert [active2] = T.active_rows(old.user_id, old.device_id)
      assert active2["access_token_hash"] == T.token_hash(body2["access_token"])
      assert active2["session_expires_at"] == original
    end

    test "the next login after the change gets the new ceiling while the old session keeps its own", ctx do
      now = System.system_time(:second)
      old = login(ctx)
      old_ceiling = ceiling(old)
      L.assert_ceiling(old_ceiling, now, 28_800, 60)

      save!("7200")

      now = System.system_time(:second)
      fresh = login(ctx)
      L.assert_ceiling(ceiling(fresh), now, 7200, 60)
      assert ceiling(old) == old_ceiling
      assert DateTime.compare(ceiling(fresh), old_ceiling) == :lt
    end
  end
end
