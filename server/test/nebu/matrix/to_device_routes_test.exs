defmodule Nebu.Matrix.ToDeviceRoutesTest do
  @moduledoc """
  Unit acceptance tests (router level, NO database: they run in the DB-less unit job) of the ROUTE of story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012):

    * `PUT /_matrix/client/v3/sendToDevice/{eventType}/{txnId}` exists behind the authentication plug: `401 M_MISSING_TOKEN` without a token, `401 M_UNKNOWN_TOKEN` for a junk token
      (today the path falls through to `404 M_UNRECOGNIZED` BEFORE the authentication);
    * AUTHENTICATION COMES BEFORE THE BODY (lesson of the sibling story's Kassandra review): `JsonBody` leaves the body of the route unfetched, so an anonymous or junk-bearer request is
      answered 401 WITHOUT its body being read, whatever its size and whatever spelling of the path (`sendTo%44evice`, `v%33`, `%5Fmatrix`, `//`); the proof is that `conn.body_params` is
      still unfetched in the answer. The route reads the body (64 KiB cap) only after the authentication and the sender's rate limit;
    * the methods that do not route answer `405 M_UNRECOGNIZED` with `Allow: PUT, OPTIONS`; paths that are not the shape of the story stay `404 M_UNRECOGNIZED`;
    * the `RouteNormalizer` replaces the client-chosen event type and txn id of the path (the log store must not persist them), the `RawBodyReader` knows the path shape so that the
      `RequestLogger` never captures a body of it;
    * the DEFAULT limits are the numbers of the story and of the decisions (`Nebu.Matrix.ToDeviceStore.limits/0`).

  The inventory of the route clauses of `Nebu.Web.Router.Protected` is pinned by `unrecognized_routes_test.exs` (AC12, extended in this story); the behaviour is `to_device_*_http_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.Web.LogStore.RouteNormalizer

  @p "/_matrix/client/v3/sendToDevice"

  defp allow_set(conn), do: conn |> Plug.Conn.get_resp_header("allow") |> List.first() |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
  defp body, do: Jason.encode!(%{"messages" => %{"@bob:test.local" => %{"*" => %{"k" => "v"}}}})
  defp pad_to(json, total), do: json <> String.duplicate(" ", total - byte_size(json))

  describe "the route is authenticated" do
    test "without a token: 401 M_MISSING_TOKEN, with and without a body, whatever the (even invalid) event type" do
      for path <- [@p <> "/m.dummy/t1", @p <> "/bad%20type%21/t1", @p <> "/m.dummy/" <> String.duplicate("t", 300)], body <- [nil, %{"messages" => %{}}] do
        c = TD.req(:put, path, nil, body)
        assert {c.status, TD.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{path}: #{c.status} #{String.slice(c.resp_body, 0, 120)}"
      end
    end

    test "a junk token (opaque or JWT-shaped): 401 M_UNKNOWN_TOKEN" do
      for token <- ["not-a-token", "aaa.bbb.ccc"] do
        c = TD.req(:put, @p <> "/m.dummy/t1", token, %{"messages" => %{}})
        assert {c.status, TD.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, "#{token}: #{c.status} #{String.slice(c.resp_body, 0, 120)}"
      end
    end

    test "an access_token QUERY parameter, a non-bearer header and an empty Bearer are no credentials" do
      for {label, c} <- [
            {"query", TD.req(:put, @p <> "/m.dummy/t1?access_token=abc", nil, %{"messages" => %{}})},
            {"Basic", TD.req(:put, @p <> "/m.dummy/t1", {:header, "Basic dXNlcjpwdw=="}, %{"messages" => %{}})},
            {"empty Bearer", TD.req(:put, @p <> "/m.dummy/t1", {:header, "Bearer "}, %{"messages" => %{}})}
          ] do
        assert {c.status, TD.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, label
      end
    end
  end

  describe "authentication comes before the body (no pre-auth read or parse)" do
    @sizes [65_537, 1_000_001, 6 * 1024 * 1024]

    defp assert_unread(c, label), do: assert(match?(%Plug.Conn.Unfetched{}, c.body_params), "#{label}: the body of an unauthenticated request was read / parsed")

    test "no token + 64 KiB + 1, 1 000 001 bytes or 6 MiB is 401 M_MISSING_TOKEN (never 413 / 400 / 5xx) and the body is never read" do
      for size <- @sizes do
        c = TD.req(:put, @p <> "/m.dummy/t1", nil, {:raw, pad_to(body(), size)})
        assert {c.status, TD.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{size}: #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert_unread(c, "#{size}")
      end
    end

    test "a junk bearer (opaque or JWT-shaped) + 64 KiB + 1 .. 6 MiB is 401 M_UNKNOWN_TOKEN, the body is never read" do
      for size <- @sizes, token <- ["junk-token", "aaa.bbb.ccc"] do
        c = TD.req(:put, @p <> "/m.dummy/t1", token, {:raw, pad_to(body(), size)})
        assert {c.status, TD.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, "#{size} #{token}: #{c.status}"
        assert_unread(c, "#{size} #{token}")
      end
    end

    test "no token or a junk token + malformed or non-object JSON: 401, never M_NOT_JSON / M_BAD_JSON, body unread" do
      for raw <- ["{nope", "[1,2]", ~s("text"), ""], token <- [nil, "junk-token"] do
        c = TD.req(:put, @p <> "/m.dummy/t1", token, {:raw, raw})
        assert c.status == 401, "#{inspect(raw)} #{inspect(token)}: #{c.status} #{c.resp_body}"
        assert_unread(c, "#{inspect(raw)} #{inspect(token)}")
      end
    end

    # `Plug.Router` matches on the DECODED path segments, so these are the very same route as `sendToDevice`; the skip clause of `JsonBody` must see the decoded segments too
    @encoded_prefixes [
      "/_matrix/client/v3/sendTo%44evice",
      "/_matrix/client/v3/%73endToDevice",
      "/_matrix/client/v3/sendToDevic%65",
      "/_matrix/client/v%33/sendToDevice",
      "/_matrix/%63lient/v3/sendToDevice",
      "/%5Fmatrix/client/v3/sendToDevice",
      "/_matrix/client//v3/sendTo%44evice",
      "/_matrix/client/v3//sendToDevice"
    ]

    test "an ENCODED sendToDevice path: no token + 64 KiB + 1 .. 6 MiB is 401, never 413, body unread" do
      for prefix <- @encoded_prefixes, size <- @sizes do
        path = prefix <> "/m.dummy/t1"
        c = TD.req(:put, path, nil, {:raw, pad_to(body(), size)})
        assert {c.status, TD.json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "PUT #{path} (#{size}): #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert_unread(c, "PUT #{path} (#{size})")
      end
    end

    test "an ENCODED sendToDevice path with a junk bearer + 6 MiB is 401 M_UNKNOWN_TOKEN, body unread" do
      for prefix <- @encoded_prefixes do
        c = TD.req(:put, prefix <> "/m.dummy/t1", "junk-token", {:raw, pad_to(body(), 6 * 1024 * 1024)})
        assert {c.status, TD.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, prefix
        assert_unread(c, prefix)
      end
    end

    test "the change is limited to this route: an anonymous 1 000 001 byte createRoom keeps its pre-router parse and answers 413" do
      c = TD.req(:post, "/_matrix/client/v3/createRoom", nil, {:raw, pad_to(~s({"name":"x"}), 1_000_001)})
      assert {c.status, TD.json(c)} == {413, %{"errcode" => "M_TOO_LARGE", "error" => "Request body is too large"}}
    end
  end

  describe "wrong methods: 405 M_UNRECOGNIZED + Allow: PUT, OPTIONS" do
    @unsupported %{"errcode" => "M_UNRECOGNIZED", "error" => "Unsupported method"}

    test "GET, POST, DELETE and PATCH on a sendToDevice path, with and without a token" do
      for method <- [:get, :post, :delete, :patch], token <- [nil, "junk-token"] do
        c = TD.req(method, @p <> "/m.dummy/t1", token)
        assert c.status == 405 and TD.json(c) == @unsupported, "#{method} #{inspect(token)}: #{c.status} #{c.resp_body}"
        assert allow_set(c) == MapSet.new(["PUT", "OPTIONS"])
      end
    end

    test "a non-preflight OPTIONS is 204 with the Allow of the path" do
      c = TD.req(:options, @p <> "/m.dummy/t1", nil)
      assert c.status == 204
      assert allow_set(c) == MapSet.new(["PUT", "OPTIONS"])
    end
  end

  describe "paths that are not the shape of the story stay unrouted" do
    @unrecognized %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}

    test "/sendToDevice, /sendToDevice/{type} and /sendToDevice/{type}/{txn}/{more} are 404 M_UNRECOGNIZED for every method, without a token" do
      for path <- [@p, @p <> "/", @p <> "/m.dummy", @p <> "/m.dummy/", @p <> "/m.dummy/t1/extra", @p <> "/m.dummy/t1/extra/more"], method <- [:get, :put, :post, :delete] do
        c = TD.req(method, path, nil)
        assert c.status == 404 and TD.json(c) == @unrecognized, "#{method} #{path}: #{c.status} #{c.resp_body}"
      end
    end

    test "other API versions and prefixes are not aliases: only /_matrix/client/v3/sendToDevice is routed" do
      for prefix <- ["/_matrix/client/r0/sendToDevice", "/_matrix/client/v1/sendToDevice", "/_matrix/client/unstable/sendToDevice", "/_matrix/media/v3/sendToDevice"] do
        c = TD.req(:put, prefix <> "/m.dummy/t1", nil)
        assert c.status == 404 and TD.json(c)["errcode"] == "M_UNRECOGNIZED", "#{prefix}: #{c.status} #{c.resp_body}"
      end
    end
  end

  describe "route normalizer anchors: the event type and the txn id of the path never reach the log store" do
    @t "/_matrix/client/v3/sendToDevice/:event_type/:txn_id"

    test "the template of every spelling is `/sendToDevice/:event_type/:txn_id`" do
      for path <- [
            "/_matrix/client/v3/sendToDevice/m.key.verification.request/secret-txn-123",
            "/_matrix/client/v3/sendToDevice/org.example.private-type/0123456789abcdef0123456789abcdef0123",
            "/_matrix/client/v3/sendToDevice/m.dummy/!room:server",
            "/_matrix/client/v3/sendToDevice/m.dummy/@user:server",
            "/_matrix/client/v3/sendToDevice/m.dummy/a%2Fb",
            "/_matrix/client/v3/sendTo%44evice/m.dummy/secret",
            "/_matrix/client/v3/%73endToDevice/m.dummy/secret",
            "/_matrix/client/v3//sendToDevice//m.dummy//secret",
            "/_matrix/client/v3/sendToDevice/m.dummy/secret/"
          ] do
        t = RouteNormalizer.normalize_route(path)
        refute t =~ "secret", path
        refute t =~ "private-type", path
        refute t =~ "m.dummy" or t =~ "m.key.verification", "#{path}: the event type is client-chosen: #{t}"
        # (the literal anchor segment keeps its input spelling, like every anchor; only the client-chosen segments are replaced)
        flat = String.replace(t, ~r{/+}, "/") |> String.trim_trailing("/")
        assert flat =~ ~r{\A/_matrix/client/v3/[^/]+/:event_type/:txn_id\z}, "#{path} -> #{t}"
        if not String.contains?(path, "%"), do: assert(flat == @t, "#{path} -> #{t}")
      end
    end

    test "a missing txn id keeps the template short (no crash on `/sendToDevice/{type}`), other routes keep their templates" do
      assert RouteNormalizer.normalize_route("/_matrix/client/v3/sendToDevice/m.dummy") == "/_matrix/client/v3/sendToDevice/:event_type"
      assert RouteNormalizer.normalize_route("/_matrix/client/v3/rooms/!r:s/send/m.room.message/txn1") == "/_matrix/client/v3/rooms/:room_id/send/:event_type/:txn_id"
      assert RouteNormalizer.normalize_route("/_matrix/client/v3/sync") == "/_matrix/client/v3/sync"
    end
  end

  describe "the request logger never captures a body of the route" do
    test "RawBodyReader.to_device_shape?/1 is true for every sendToDevice path (any version, any spelling), false for the others" do
      shape = fn path -> apply(Nebu.Web.Plugs.RawBodyReader, :to_device_shape?, [path]) end

      for path <- ["/_matrix/client/v3/sendToDevice/m.dummy/t1", "/_matrix/client/r0/sendToDevice/m.dummy/t1", "/_matrix/client/v3/sendTo%44evice/m.dummy/t1", "/_matrix/client/v3//sendToDevice/x/y", "/_matrix/client/v3/sendToDevice"],
          do: assert(shape.(path), path)

      for path <- ["/_matrix/client/v3/sync", "/_matrix/client/v3/rooms/!r:s/send/m.dummy/t1", "/_matrix/client/v3/user/@u:s/account_data/sendToDevice", "/other/sendToDevice/a/b"],
          do: refute(shape.(path), path)
    end
  end

  describe "the default limits (the numbers of the story and of the orchestrator decisions)" do
    test "Nebu.Matrix.ToDeviceStore.limits/0 returns the pinned defaults when no seam is set" do
      limits = apply(Nebu.Matrix.ToDeviceStore, :limits, [])
      pinned = Map.take(TD.defaults(), ~w(max_per_device max_bytes_per_device max_per_user max_bytes_per_user max_per_sender_device max_bytes_per_sender_device max_per_sender_user max_bytes_per_sender_user max_per_sender_total max_bytes_per_sender_total max_targets_per_request max_fanout_bytes_per_request max_txns_per_device sync_batch_size sync_batch_bytes ttl_seconds txn_ttl_seconds rate_bytes_per_min rate_bytes_burst statement_timeout_ms)a)
      assert map_size(pinned) == 20
      for {key, value} <- pinned, do: assert(limits[key] == value, "#{key}: #{inspect(limits[key])} != #{value}")
      assert apply(Nebu.Matrix.ToDeviceStore, :row_overhead, []) == 128
    end

    test "the cycle 1 numbers literally: 1 MiB sender-device share, 4000 / 16 MiB sender total, 4 MiB / min bucket, 8 MiB burst, 2000 ms" do
      limits = apply(Nebu.Matrix.ToDeviceStore, :limits, [])

      assert {limits.max_bytes_per_sender_device, limits.max_per_sender_total, limits.max_bytes_per_sender_total} == {1_048_576, 4000, 16_777_216}
      assert {limits.rate_bytes_per_min, limits.rate_bytes_burst, limits.statement_timeout_ms} == {4_194_304, 8_388_608, 2000}
    end

    test "the send slots default to 4 per user and 6 per node (Nebu.Matrix.ToDeviceSendGate)" do
      assert apply(Nebu.Matrix.ToDeviceSendGate, :max_per_user, []) == TD.defaults().max_concurrent_sends_per_user
      assert apply(Nebu.Matrix.ToDeviceSendGate, :max_per_node, []) == TD.defaults().max_concurrent_sends_per_node
      assert {apply(Nebu.Matrix.ToDeviceSendGate, :max_per_user, []), apply(Nebu.Matrix.ToDeviceSendGate, :max_per_node, [])} == {4, 6}
    end

    test "a seam overrides one limit and leaves the others (read at call time)" do
      key = :to_device_max_per_device
      old = Application.fetch_env(:nebu, key)
      Application.put_env(:nebu, key, 7)

      try do
        limits = apply(Nebu.Matrix.ToDeviceStore, :limits, [])
        assert limits.max_per_device == 7
        assert limits.max_per_user == TD.defaults().max_per_user
      after
        case old do
          {:ok, v} -> Application.put_env(:nebu, key, v)
          :error -> Application.delete_env(:nebu, key)
        end
      end
    end

    test "a seam that is not a positive integer is ignored (the default stays)" do
      key = :to_device_max_per_device
      old = Application.fetch_env(:nebu, key)

      try do
        for bad <- [0, -1, "5", nil, 1.5] do
          Application.put_env(:nebu, key, bad)
          assert apply(Nebu.Matrix.ToDeviceStore, :limits, []).max_per_device == 500, "seam #{inspect(bad)}"
        end
      after
        case old do
          {:ok, v} -> Application.put_env(:nebu, key, v)
          :error -> Application.delete_env(:nebu, key)
        end
      end
    end
  end
end
