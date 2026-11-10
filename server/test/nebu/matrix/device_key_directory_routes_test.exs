defmodule Nebu.Matrix.DeviceKeyDirectoryRoutesTest do
  @moduledoc """
  Unit acceptance tests (router level, NO database: they run in the DB-less unit job) of the two ROUTES of story `device-key-directory` (epic e2ee-client-support, REQ-2026-013):

    * `POST /_matrix/client/v3/keys/claim` and `GET /_matrix/client/v3/keys/changes` exist behind the authentication plug: `401 M_MISSING_TOKEN` without a token, `401 M_UNKNOWN_TOKEN` for a
      junk token, whatever the body or the query (today both paths fall through to `404 M_UNRECOGNIZED` BEFORE the authentication); the authentication comes before the validation (an
      anonymous request with a malformed body or token parameter is a 401, never a 400);
    * the methods that do not route answer `405 M_UNRECOGNIZED` with the right `Allow` set; paths next to them stay `404 M_UNRECOGNIZED`;
    * an encoded spelling of the path (`clai%6D`) reaches the same route (the router matches the DECODED segments), so it is authenticated too.

  The inventory of the route clauses of `Nebu.Web.Router.Protected` is pinned by `unrecognized_routes_test.exs` (AC12, extended in this story); the behaviour is
  `device_key_directory_claim_*_test.exs` and `device_key_directory_changes_http_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Web.SessionLookupTestSupport, as: LookupFault

  alias Nebu.Matrix.ToDeviceTestSupport, as: TD

  @claim "/_matrix/client/v3/keys/claim"
  @changes "/_matrix/client/v3/keys/changes"

  defp allow_set(conn), do: conn |> Plug.Conn.get_resp_header("allow") |> List.first() |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
  defp errcode(c), do: {c.status, TD.json(c)["errcode"]}

  describe "POST /keys/claim is authenticated" do
    test "without a token: 401 M_MISSING_TOKEN, with and without a body, valid or garbage" do
      for body <- [nil, %{"one_time_keys" => %{}}, %{"one_time_keys" => "broken"}, {:raw, "{not json"}] do
        assert errcode(TD.req(:post, @claim, nil, body)) == {401, "M_MISSING_TOKEN"}
      end
    end

    test "a junk token (opaque or JWT-shaped): 401 M_UNKNOWN_TOKEN" do
      LookupFault.setup_no_row_lookup()
      for token <- ["not-a-token", "aaa.bbb.ccc"], do: assert(errcode(TD.req(:post, @claim, token, %{"one_time_keys" => %{}})) == {401, "M_UNKNOWN_TOKEN"})
    end

    test "an access_token QUERY parameter, a non-bearer header and an empty Bearer are no credentials" do
      for c <- [
            TD.req(:post, @claim <> "?access_token=abc", nil, %{"one_time_keys" => %{}}),
            TD.req(:post, @claim, {:header, "Basic dXNlcjpwdw=="}, %{"one_time_keys" => %{}}),
            TD.req(:post, @claim, {:header, "Bearer "}, %{"one_time_keys" => %{}})
          ] do
        assert errcode(c) == {401, "M_MISSING_TOKEN"}
      end
    end

    test "an encoded spelling of the path reaches the same authenticated route" do
      assert errcode(TD.req(:post, "/_matrix/client/v3/keys/clai%6D", nil, %{"one_time_keys" => %{}})) == {401, "M_MISSING_TOKEN"}
      assert errcode(TD.req(:post, "/_matrix/client/v%33/keys/claim", nil, %{"one_time_keys" => %{}})) == {401, "M_MISSING_TOKEN"}
    end

    test "authentication comes before the 1000 target cap: an anonymous request with 2000 targets is a 401" do
      many = for i <- 1..2000, into: %{}, do: {"@u#{i}:test.local", %{"D" => "signed_curve25519"}}
      assert errcode(TD.req(:post, @claim, nil, %{"one_time_keys" => many})) == {401, "M_MISSING_TOKEN"}
    end
  end

  describe "GET /keys/changes is authenticated" do
    test "without a token: 401 M_MISSING_TOKEN, with valid, missing and malformed parameters alike" do
      for q <- ["", "?from=s2_x.1.d1&to=s2_x.1.d2", "?from=!!!&to=%00", "?from[]=a&to[]=b"] do
        assert errcode(TD.req(:get, @changes <> q, nil)) == {401, "M_MISSING_TOKEN"}, q
      end
    end

    test "a junk token: 401 M_UNKNOWN_TOKEN" do
      LookupFault.setup_no_row_lookup()
      for token <- ["not-a-token", "aaa.bbb.ccc"], do: assert(errcode(TD.req(:get, @changes <> "?from=a&to=b", token)) == {401, "M_UNKNOWN_TOKEN"})
    end

    test "an access_token QUERY parameter is no credential" do
      assert errcode(TD.req(:get, @changes <> "?access_token=abc&from=a&to=b", nil)) == {401, "M_MISSING_TOKEN"}
    end

    test "an encoded spelling of the path reaches the same authenticated route" do
      assert errcode(TD.req(:get, "/_matrix/client/v3/keys/chang%65s?from=a&to=b", nil)) == {401, "M_MISSING_TOKEN"}
    end
  end

  describe "methods and neighbours" do
    test "claim routes POST only: GET, PUT and DELETE are 405 M_UNRECOGNIZED with Allow POST, with and without a token" do
      for method <- [:get, :put, :delete], token <- [nil, "junk-" <> "token"] do
        c = TD.req(method, @claim, token)
        assert errcode(c) == {405, "M_UNRECOGNIZED"}, "#{method} #{inspect(token)}"
        assert MapSet.member?(allow_set(c), "POST") and not MapSet.member?(allow_set(c), "GET")
      end
    end

    test "changes routes GET only: POST, PUT and DELETE are 405 M_UNRECOGNIZED with Allow GET" do
      for method <- [:post, :put, :delete] do
        c = TD.req(method, @changes, nil)
        assert errcode(c) == {405, "M_UNRECOGNIZED"}, "#{method}"
        assert MapSet.member?(allow_set(c), "GET") and not MapSet.member?(allow_set(c), "POST")
      end
    end

    test "neighbouring paths are no routes: /keys/claims, /keys/claim/x and /keys/change stay 404 M_UNRECOGNIZED" do
      for path <- ["/_matrix/client/v3/keys/claims", "/_matrix/client/v3/keys/claim/x", "/_matrix/client/v3/keys/change"] do
        assert errcode(TD.req(:post, path, nil, %{})) == {404, "M_UNRECOGNIZED"}, path
      end
    end
  end
end
