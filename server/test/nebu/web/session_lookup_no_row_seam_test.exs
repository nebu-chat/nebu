defmodule Nebu.Web.SessionLookupNoRowSeamTest do
  @moduledoc """
  Pins the test-only "no such row" outcome of the access-token lookup seam used by
  `Nebu.Web.SessionLookupTestSupport.setup_no_row_lookup/0` (bugfix unit-tests-junk-token-503-after-lookup-fix):
  an unknown token is `:error` / `401 M_UNKNOWN_TOKEN` (the client drops its session), NOT the retryable
  `503` of a failed lookup (that contract is `oidc_plug_lookup_failure_test.exs`). Needs no database.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store
  alias Nebu.Web.SessionLookupTestSupport, as: LookupFault

  @router_opts Nebu.Web.Router.init([])
  @fault_key :matrix_session_lookup_fault

  test "the seam is unset at the start of a test (a previous test's helper call does not leak)" do
    assert Application.get_env(:nebu_http, @fault_key) == nil
  end

  test "setup_no_row_lookup/0: the lookup answers :error (no such row), never {:error, :unavailable}" do
    LookupFault.setup_no_row_lookup()

    assert Store.get_by_access_token("not-a-real-token") == :error
  end

  test "setup_no_row_lookup/0: a junk opaque bearer is 401 M_UNKNOWN_TOKEN without Retry-After, nothing authenticated" do
    LookupFault.setup_no_row_lookup()

    conn =
      conn(:get, "/_matrix/client/v3/account/whoami")
      |> put_req_header("authorization", "Bearer not-a-real-token")
      |> Nebu.Web.Router.call(@router_opts)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    assert get_resp_header(conn, "retry-after") == []
    refute Map.has_key?(conn.assigns, :current_user)
  end
end
