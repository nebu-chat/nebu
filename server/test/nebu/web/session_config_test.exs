defmodule Nebu.Web.SessionConfigTest do
  @moduledoc """
  Guards the configurable session-TTL seam (story e2e-session-refresh-suites, AC1/AC7).

  This is the unit-level half of the seam's coverage: it proves the accessors default to 8h
  when unset (AC7 — production behavior unchanged), honor a configured override (AC1), and
  that the defensive parser used by runtime.exs rejects junk / non-positive values so a
  misconfigured env var can never shorten or crash the login path. The end-to-end half
  (the opaque-AT login + /v3/refresh re-mint and the admin silent refresh actually honoring
  a short TTL) is covered by the three browser e2e suites.
  """
  use ExUnit.Case, async: false

  alias Nebu.Web.SessionConfig

  @eight_hours 8 * 3600

  describe "defaults (AC7 — unset == previous hardcoded 8h)" do
    test "default constants are 8h" do
      assert SessionConfig.default_matrix_ttl_seconds() == @eight_hours
      assert SessionConfig.default_admin_ttl_seconds() == @eight_hours
    end

    test "matrix accessor returns 8h when the app env key is unset" do
      Application.delete_env(:nebu_http, :matrix_session_ttl_seconds)
      assert SessionConfig.matrix_session_ttl_seconds() == @eight_hours
    end

    test "admin accessor returns 8h when the app env key is unset" do
      Application.delete_env(:nebu_http, :admin_session_ttl_seconds)
      assert SessionConfig.admin_session_ttl_seconds() == @eight_hours
    end
  end

  describe "configured override (AC1)" do
    test "matrix accessor returns the configured value" do
      Application.put_env(:nebu_http, :matrix_session_ttl_seconds, 30)
      on_exit(fn -> Application.delete_env(:nebu_http, :matrix_session_ttl_seconds) end)
      assert SessionConfig.matrix_session_ttl_seconds() == 30
    end

    test "admin accessor returns the configured value" do
      Application.put_env(:nebu_http, :admin_session_ttl_seconds, 45)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_session_ttl_seconds) end)
      assert SessionConfig.admin_session_ttl_seconds() == 45
    end
  end

  describe "parse_ttl/1 (defensive — runtime.exs uses this; AC1)" do
    test "a positive integer string parses" do
      assert SessionConfig.parse_ttl("30") == {:ok, 30}
      assert SessionConfig.parse_ttl("  45  ") == {:ok, 45}
    end

    test "nil / junk / non-positive are :invalid (default left untouched)" do
      assert SessionConfig.parse_ttl(nil) == :invalid
      assert SessionConfig.parse_ttl("") == :invalid
      assert SessionConfig.parse_ttl("abc") == :invalid
      assert SessionConfig.parse_ttl("0") == :invalid
      assert SessionConfig.parse_ttl("-5") == :invalid
      assert SessionConfig.parse_ttl("30x") == :invalid
      assert SessionConfig.parse_ttl("3.5") == :invalid
    end
  end
end
