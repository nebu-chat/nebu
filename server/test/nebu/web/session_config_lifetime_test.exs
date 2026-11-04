defmodule Nebu.Web.SessionConfigLifetimeTest do
  @moduledoc """
  Story `session-lifetime-setting` (epic oauth-session-and-consent), scenarios 1 and 2 at the accessor level, no database: the order of the sources of
  `Nebu.Web.SessionConfig.matrix_session_ttl_seconds/0` (the ceiling every Matrix session issuer stamps at login):

      saved value (`server_config.matrix_session_ttl_seconds`, whole seconds 3600..7_776_000)
        > env `NEBU_MATRIX_SESSION_TTL_SECONDS` (`:nebu_http, :matrix_session_ttl_seconds`)
        > 8 hours

  A saved value that is damaged, out of range or unreadable is IGNORED (never clamped, never an exception: the login path must not crash) and the
  next source answers. The stored value is read through `Nebu.OAuth.Config` (per-node cache, seam `:oauth_config_source` with the optional map key
  `:matrix_session_ttl_seconds`, see `Nebu.SessionLifetime.TestSupport`). The legacy login (`Nebu.Matrix.HttpPublic.session_expires_at/1`) reads the
  same accessor.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.HttpPublic
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L
  alias Nebu.Web.SessionConfig

  setup do
    L.clear_env_ttl!()
    T.clear_oauth_config()
    on_exit(fn -> T.clear_oauth_config() end)
    :ok
  end

  describe "scenario 1 - nothing saved: the 8 hour ceiling" do
    test "no saved value and no env: 8 hours" do
      L.seam_stored(:absent)
      assert SessionConfig.matrix_session_ttl_seconds() == 28_800
      assert SessionConfig.matrix_session_ttl_seconds() == SessionConfig.default_matrix_ttl_seconds()
    end

    test "no config source at all (no seam): 8 hours" do
      T.clear_oauth_config()
      assert SessionConfig.matrix_session_ttl_seconds() == 28_800
    end

    test "the env value is the fallback below a saved value, and is not range checked (the e2e stack uses 30 seconds)" do
      for env <- [30, 600, 14_400] do
        L.put_env_ttl!(env)
        L.seam_stored(:absent)
        assert SessionConfig.matrix_session_ttl_seconds() == env
      end
    end
  end

  describe "scenario 2 - a saved lifetime applies" do
    test "a saved value (text as stored, or an integer) is the ceiling" do
      for {raw, seconds} <- [{"7200", 7200}, {7200, 7200}, {"28800", 28_800}, {"86400", 86_400}, {" 7200 ", 7200}] do
        L.seam_stored(raw)
        assert SessionConfig.matrix_session_ttl_seconds() == seconds, "stored #{inspect(raw)}"
      end
    end

    test "the bounds are in: 3600 and 7_776_000 (90 days), as text and as an integer" do
      for raw <- ["3600", 3600] do
        L.seam_stored(raw)
        assert SessionConfig.matrix_session_ttl_seconds() == 3600
      end

      for raw <- ["7776000", 7_776_000] do
        L.seam_stored(raw)
        assert SessionConfig.matrix_session_ttl_seconds() == 7_776_000
      end
    end

    test "a saved value wins over the env value, longer or shorter" do
      L.put_env_ttl!(30)
      L.seam_stored("7200")
      assert SessionConfig.matrix_session_ttl_seconds() == 7200

      L.put_env_ttl!(14_400)
      L.seam_stored("3600")
      assert SessionConfig.matrix_session_ttl_seconds() == 3600
    end

    test "the saved value is read on every call (no value is frozen at boot)" do
      L.seam_stored("7200")
      assert SessionConfig.matrix_session_ttl_seconds() == 7200
      L.seam_stored("10800")
      assert SessionConfig.matrix_session_ttl_seconds() == 10_800
      L.seam_stored(:absent)
      assert SessionConfig.matrix_session_ttl_seconds() == 28_800
    end
  end

  describe "a damaged, out-of-range or unreadable saved value is ignored: the env value, else 8 hours, never a crash" do
    @damaged ["", " ", "abc", "7200.5", "7200s", "-7200", "1e4", "7_200", "0x1C20", "3599", "0", "100", "7776001", "99999999999999999999", "2 hours", "7200\n7200"]

    test "no env: 8 hours" do
      for raw <- @damaged do
        L.seam_stored(raw)
        assert SessionConfig.matrix_session_ttl_seconds() == 28_800, "stored #{inspect(raw)}"
      end
    end

    test "with an env value: the env value" do
      L.put_env_ttl!(14_400)

      for raw <- @damaged do
        L.seam_stored(raw)
        assert SessionConfig.matrix_session_ttl_seconds() == 14_400, "stored #{inspect(raw)}"
      end
    end

    test "values that are not text or a number (nil, an atom, a list, a map, a float) are ignored" do
      for raw <- [nil, :two_hours, [7200], %{"v" => 7200}, 7200.0, -1, 3599, 7_776_001] do
        L.seam_stored(raw)
        assert SessionConfig.matrix_session_ttl_seconds() == 28_800, "stored #{inspect(raw)}"
      end
    end

    test "an unreadable server_config (the unknown state of the config source) answers the env value / 8 hours" do
      T.unreadable_oauth_config()
      assert SessionConfig.matrix_session_ttl_seconds() == 28_800

      L.put_env_ttl!(600)
      assert SessionConfig.matrix_session_ttl_seconds() == 600

      Application.put_env(:nebu_http, :oauth_config_source, fn -> {:error, :timeout} end)
      assert SessionConfig.matrix_session_ttl_seconds() == 600
    end

    test "the damaged text never reaches the log (no sensitive value in logs, only the number or nothing)" do
      raw = "canary-ttl-4711-secret"
      L.seam_stored(raw)
      log = capture_log([level: :debug], fn -> assert SessionConfig.matrix_session_ttl_seconds() == 28_800 end)
      refute log =~ "canary-ttl-4711", log
    end
  end

  describe "the legacy login ceiling (HttpPublic.session_expires_at/1) reads the same accessor" do
    test "far IdP expiry: now + saved lifetime, shorter and longer than 8 hours" do
      for {raw, seconds} <- [{"7200", 7200}, {"86400", 86_400}, {:absent, 28_800}] do
        L.seam_stored(raw)
        now = System.system_time(:second)
        L.assert_ceiling(HttpPublic.session_expires_at(%{"exp" => now + 10_000_000}), now, seconds)
      end
    end

    test "an IdP token that expires earlier than the ceiling still wins (min semantics unchanged)" do
      L.seam_stored("7200")
      now = System.system_time(:second)
      assert DateTime.to_unix(HttpPublic.session_expires_at(%{"exp" => now + 600})) == now + 600
    end

    test "no usable exp claim: the ceiling" do
      L.seam_stored("10800")
      now = System.system_time(:second)
      L.assert_ceiling(HttpPublic.session_expires_at(%{}), now, 10_800)
    end

    test "a damaged saved value: the env value is the ceiling" do
      L.put_env_ttl!(14_400)
      L.seam_stored("garbage")
      now = System.system_time(:second)
      L.assert_ceiling(HttpPublic.session_expires_at(%{"exp" => now + 10_000_000}), now, 14_400)
    end
  end

  describe "the admin session ceiling is not part of this story" do
    test "a saved Matrix lifetime does not change Nebu.Web.SessionConfig.admin_session_ttl_seconds/0" do
      L.seam_stored("7200")
      T.put_env_scoped(:admin_session_ttl_seconds, 45)
      assert SessionConfig.admin_session_ttl_seconds() == 45

      T.put_env_scoped(:admin_session_ttl_seconds, nil)
      Application.delete_env(:nebu_http, :admin_session_ttl_seconds)
      assert SessionConfig.admin_session_ttl_seconds() == 28_800
      assert SessionConfig.admin_session_ttl_seconds() == SessionConfig.default_admin_ttl_seconds()
    end

    test "Nebu.Admin.Auth (the admin session) does not read the saved lifetime" do
      src = File.read!(Path.expand("../../../lib/nebu/admin/auth.ex", __DIR__))
      refute src =~ "matrix_session_ttl"
      refute src =~ "Nebu.OAuth.matrix_session"
      refute src =~ "Nebu.OAuth.Config"
    end
  end
end
