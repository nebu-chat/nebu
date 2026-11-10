defmodule Nebu.Matrix.RoomKeysRoutesTest do
  @moduledoc """
  Unit acceptance tests (router level, NO database: they run in the DB-less unit job) of the ROUTE TABLE of story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011):

    * the 14 clauses of the story exist behind the authentication plug: each of them answers `401 M_MISSING_TOKEN` without a token and `401 M_UNKNOWN_TOKEN` for a junk token
      (before today only `GET|POST /room_keys/version` were routed; the keys and `/version/{version}` routes fell through to `404 M_UNRECOGNIZED` BEFORE the authentication);
    * the methods that do not route on a room_keys path answer `405 M_UNRECOGNIZED` with the exact `Allow` set (`/version`: GET, POST; every other room_keys path: GET, PUT, DELETE;
      `OPTIONS` is always appended), a non-preflight `OPTIONS` is `204`;
    * paths that are not one of the story's shapes stay `404 M_UNRECOGNIZED` (no route swallows `/room_keys`, `/room_keys/keys/a/b/c` or `/room_keys/version/1/x`).

  The inventory of the route clauses of `Nebu.Web.Router.Protected` is pinned by `unrecognized_routes_test.exs` (AC12, extended in this story); the behaviour is
  `room_keys_*_http_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Web.SessionLookupTestSupport, as: LookupFault

  alias Nebu.Matrix.RoomKeysTestSupport, as: RK

  @p "/_matrix/client/v3/room_keys"
  @room "%21room%3Atest.local"

  # {method, concrete path} of the 14 clauses
  @clauses [
    {:get, @p <> "/version"},
    {:post, @p <> "/version"},
    {:get, @p <> "/version/1"},
    {:put, @p <> "/version/1"},
    {:delete, @p <> "/version/1"},
    {:get, @p <> "/keys?version=1"},
    {:put, @p <> "/keys?version=1"},
    {:delete, @p <> "/keys?version=1"},
    {:get, @p <> "/keys/#{@room}?version=1"},
    {:put, @p <> "/keys/#{@room}?version=1"},
    {:delete, @p <> "/keys/#{@room}?version=1"},
    {:get, @p <> "/keys/#{@room}/sess?version=1"},
    {:put, @p <> "/keys/#{@room}/sess?version=1"},
    {:delete, @p <> "/keys/#{@room}/sess?version=1"}
  ]

  defp allow_set(conn), do: conn |> Plug.Conn.get_resp_header("allow") |> List.first() |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

  describe "the 14 routes are authenticated" do
    test "without a token each answers 401 M_MISSING_TOKEN (never the 404 / 405 of an unrouted path), with and without a body" do
      for {method, path} <- @clauses, body <- [nil, %{"algorithm" => RK.algorithm(), "auth_data" => %{}}] do
        c = RK.req(method, path, nil, body)
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{method} #{path}: #{c.status} #{String.slice(c.resp_body, 0, 120)}"
      end
    end

    test "a junk token (opaque or JWT-shaped) answers 401 M_UNKNOWN_TOKEN" do
      LookupFault.setup_no_row_lookup()
      for {method, path} <- @clauses, token <- ["not-a-token", "aaa.bbb.ccc"] do
        c = RK.req(method, path, token, nil)
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, "#{method} #{path} (#{token}): #{c.status} #{String.slice(c.resp_body, 0, 120)}"
      end
    end

    test "the unauthenticated 401 does not depend on the version query: a missing or empty one is still 401 first, not 400 M_MISSING_PARAM" do
      for path <- [@p <> "/keys", @p <> "/keys?version=", @p <> "/keys/#{@room}", @p <> "/keys/#{@room}/sess?version="], method <- [:get, :put, :delete] do
        c = RK.req(method, path, nil, nil)
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{method} #{path}"
      end
    end
  end

  # CYCLE 1 (Kassandra MEDIUM 3, orchestrator decision; SUPERSEDES the cycle-0 rule "the 5 MiB cap applies to requests that carry credentials, anonymous requests keep 1 MB"):
  # NO pre-auth parse. `JsonBody` leaves the bodies of `v3/room_keys/**` unfetched; the authenticated route reads them AFTER the authentication and the write rate limit
  # (with the 5 MiB limit). So an anonymous, junk-bearer or malformed-credential request is answered 401 WITHOUT its body being read, whatever its size (no 413, no 400,
  # no memory spent); the proof is that `conn.body_params` is still unfetched in the answer.
  describe "authentication comes before the body (no pre-auth read or parse)" do
    defp pad_to(json, total), do: json <> String.duplicate(" ", total - byte_size(json))
    defp put_body, do: Jason.encode!(%{"rooms" => %{"!r:test.local" => %{"sessions" => %{"s" => RK.kbd(1, 0, false)}}}})

    @write_routes [
      {:put, @p <> "/keys?version=1"},
      {:put, @p <> "/keys/#{@room}?version=1"},
      {:put, @p <> "/keys/#{@room}/sess?version=1"},
      {:post, @p <> "/version"},
      {:put, @p <> "/version/1"}
    ]
    @big_sizes [1_000_001, 6 * 1024 * 1024]

    defp assert_unread(c, label) do
      assert match?(%Plug.Conn.Unfetched{}, c.body_params), "#{label}: the body of an unauthenticated request was read / parsed"
    end

    test "no token + a body of 1 000 001 bytes or 6 MiB on every write route is 401 M_MISSING_TOKEN (never 413, never a 5xx) and the body is never read" do
      for {method, path} <- @write_routes, size <- @big_sizes do
        c = RK.req(method, path, nil, {:raw, pad_to(put_body(), size)})
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{method} #{path} (#{size}): #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert_unread(c, "#{method} #{path} (#{size})")
      end
    end

    test "a junk bearer (opaque or JWT-shaped) + 1 000 001 bytes or 6 MiB (above the 5 MiB cap too) is 401 M_UNKNOWN_TOKEN, never 413 / 5xx, and the body is never read" do
      LookupFault.setup_no_row_lookup()
      for {method, path} <- @write_routes, size <- @big_sizes, token <- ["junk-token", "aaa.bbb.ccc"] do
        c = RK.req(method, path, token, {:raw, pad_to(put_body(), size)})
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, "#{method} #{path} (#{size}, #{token}): #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert_unread(c, "#{method} #{path} (#{size}, #{token})")
      end
    end

    test "no token + exactly 1 000 000 bytes (a size the old default parser accepted) is 401 M_MISSING_TOKEN as well" do
      c = RK.req(:put, @p <> "/keys?version=1", nil, {:raw, pad_to(put_body(), 1_000_000)})
      assert {c.status, RK.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}
      assert_unread(c, "1 000 000 bytes")
    end

    test "an access_token QUERY parameter, a non-bearer Authorization header and an empty Bearer are no credentials: 401 M_MISSING_TOKEN, body unread" do
      big = pad_to(put_body(), 1_000_001)

      for {label, c} <- [
            {"access_token query", RK.req(:put, @p <> "/keys?version=1&access_token=not-a-token", nil, {:raw, big})},
            {"Basic", RK.req(:put, @p <> "/keys?version=1", {:header, "Basic dXNlcjpwdw=="}, {:raw, big})},
            {"empty Bearer", RK.req(:put, @p <> "/keys?version=1", {:header, "Bearer "}, {:raw, big})},
            {"bearer-ish", RK.req(:put, @p <> "/keys?version=1", {:header, "bearer-ish abc"}, {:raw, big})}
          ] do
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{label}: #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert_unread(c, label)
      end
    end

    test "no token + malformed JSON (or a non-object body) is 401 M_MISSING_TOKEN, never M_NOT_JSON / M_BAD_JSON, body unread; a junk token the same with 401 M_UNKNOWN_TOKEN" do
      LookupFault.setup_no_row_lookup()
      for raw <- ["{nope", "[1,2]", ~s("text")], {method, path} <- [{:put, @p <> "/keys?version=1"}, {:post, @p <> "/version"}, {:put, @p <> "/version/1"}] do
        c = RK.req(method, path, nil, {:raw, raw})
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{method} #{path} #{raw}"
        assert_unread(c, "#{method} #{path} #{raw}")

        c = RK.req(method, path, "junk-token", {:raw, raw})
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, "#{method} #{path} #{raw} (junk token)"
        assert_unread(c, "#{method} #{path} #{raw} (junk token)")
      end
    end

    # cycle 2 (INFO-5 of the delta review): `Plug.Router` matches on the DECODED path segments, so `room%5Fkeys` (or an encoded `v3`, `client`, `_matrix`) is the very same route as
    # `room_keys`; the skip clause of `JsonBody` must see the decoded segments too, else the pre-auth parse (1 MB cap, body read before the authentication) is back for these spellings
    @encoded_prefixes [
      "/_matrix/client/v3/room%5Fkeys",
      "/_matrix/client/v3/%72oom_keys",
      "/_matrix/client/v3/room_key%73",
      "/_matrix/client/v%33/room_keys",
      "/_matrix/%63lient/v3/room_keys",
      "/%5Fmatrix/client/v3/room_keys",
      "/_matrix/client/v3/room%5fkeys",
      "/_matrix/client//v3/room%5Fkeys"
    ]

    test "an ENCODED room_keys path (room%5Fkeys, %72oom_keys, ...): no token + 1 000 001 bytes or 6 MiB is 401, never 413, body unread" do
      for prefix <- @encoded_prefixes, size <- @big_sizes do
        path = prefix <> "/keys?version=1"
        c = RK.req(:put, path, nil, {:raw, pad_to(put_body(), size)})
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "PUT #{path} (#{size}): #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert_unread(c, "PUT #{path} (#{size})")
      end
    end

    test "an ENCODED room_keys path with a junk bearer + 6 MiB is 401 M_UNKNOWN_TOKEN, body unread (all write routes)" do
      LookupFault.setup_no_row_lookup()
      for prefix <- @encoded_prefixes, {method, suffix} <- [{:put, "/keys/#{@room}?version=1"}, {:post, "/version"}, {:put, "/version/1"}] do
        c = RK.req(method, prefix <> suffix, "junk-token", {:raw, pad_to(put_body(), 6 * 1024 * 1024)})
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, "#{method} #{prefix <> suffix}: #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert_unread(c, "#{method} #{prefix <> suffix}")
      end
    end

    test "the other Matrix routes keep their pre-router parse and their 1 MB cap (the change is limited to room_keys): an anonymous 1 000 001 byte createRoom is still 413" do
      c = RK.req(:post, "/_matrix/client/v3/createRoom", nil, {:raw, pad_to(~s({"name":"x"}), 1_000_001)})
      assert {c.status, RK.json(c)} == {413, %{"errcode" => "M_TOO_LARGE", "error" => "Request body is too large"}}
    end
  end

  describe "wrong methods: 405 M_UNRECOGNIZED + Allow" do
    @unsupported %{"errcode" => "M_UNRECOGNIZED", "error" => "Unsupported method"}

    test "/version is GET and POST (PUT, DELETE, PATCH: 405, Allow GET, POST, OPTIONS)" do
      for method <- [:put, :delete, :patch] do
        c = RK.req(method, @p <> "/version", nil)
        assert c.status == 405 and RK.json(c) == @unsupported, "#{method}: #{c.status} #{c.resp_body}"
        assert allow_set(c) == MapSet.new(["GET", "POST", "OPTIONS"])
      end
    end

    test "/version/{version}, /keys, /keys/{room} and /keys/{room}/{session} are GET, PUT and DELETE (POST, PATCH: 405, Allow GET, PUT, DELETE, OPTIONS)" do
      for path <- [@p <> "/version/1", @p <> "/keys", @p <> "/keys/#{@room}", @p <> "/keys/#{@room}/sess"], method <- [:post, :patch] do
        c = RK.req(method, path, nil)
        assert c.status == 405 and RK.json(c) == @unsupported, "#{method} #{path}: #{c.status} #{c.resp_body}"
        assert allow_set(c) == MapSet.new(["GET", "PUT", "DELETE", "OPTIONS"]), "#{method} #{path}: #{inspect(Plug.Conn.get_resp_header(c, "allow"))}"
      end
    end

    test "a non-preflight OPTIONS on every shape is 204 with the Allow of the path" do
      for {path, allow} <- [
            {@p <> "/version", ["GET", "POST"]},
            {@p <> "/version/1", ["GET", "PUT", "DELETE"]},
            {@p <> "/keys", ["GET", "PUT", "DELETE"]},
            {@p <> "/keys/#{@room}", ["GET", "PUT", "DELETE"]},
            {@p <> "/keys/#{@room}/sess", ["GET", "PUT", "DELETE"]}
          ] do
        c = RK.req(:options, path, nil)
        assert c.status == 204, "#{path}: #{c.status}"
        assert allow_set(c) == MapSet.new(allow ++ ["OPTIONS"])
      end
    end
  end

  describe "paths that are not a shape of the story stay unrouted" do
    @unrecognized %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}

    test "/room_keys, /room_keys/other, /version/{v}/x, /keys/a/b/c and deeper are 404 M_UNRECOGNIZED for every method and without any token" do
      for path <- [@p, @p <> "/", @p <> "/other", @p <> "/version/1/x", @p <> "/version/1/x/y", @p <> "/keys/a/b/c", @p <> "/keys/a/b/c/d"],
          method <- [:get, :put, :post, :delete] do
        c = RK.req(method, path, nil)
        assert c.status == 404 and RK.json(c) == @unrecognized, "#{method} #{path}: #{c.status} #{c.resp_body}"
      end
    end

    test "other API versions and prefixes are not aliases: only /_matrix/client/v3/room_keys is routed" do
      for prefix <- ["/_matrix/client/r0/room_keys", "/_matrix/client/v1/room_keys", "/_matrix/client/unstable/room_keys", "/_matrix/media/v3/room_keys"] do
        c = RK.req(:get, prefix <> "/version", nil)
        assert c.status == 404 and RK.json(c)["errcode"] == "M_UNRECOGNIZED", "#{prefix}: #{c.status} #{c.resp_body}"
      end
    end
  end
end
