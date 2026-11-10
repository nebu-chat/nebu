defmodule Nebu.Matrix.DevicePutKeepsDisplayNameTest do
  @moduledoc """
  ATDD for the bugfix `matrix-put-device-keeps-display-name` (Matrix spec v1.18, `PUT /_matrix/client/v3/devices/{deviceId}`).

  Spec: `display_name` - "If not given, the display name is unchanged." Today the handler passes a missing key as `nil` to
  `DeviceKeyStore.rename_device/3`, so `PUT {}` erases the name, and a non-string `display_name` reaches the SQL parameter and gives a wrong 404.

  Contract pinned here (decisions of the story / the Oracle):

    * `PUT {}` (no `display_name` key): 200 `{}`, the name is unchanged (GET /devices, GET /devices/{id}, POST /keys/query `unsigned.device_display_name`).
    * `PUT {"display_name": null}`: 200, the name is cleared (DB NULL; `display_name` key absent in GET /devices; no `device_display_name` in keys/query).
      The spec does not define null; this is a Nebu choice.
    * `display_name` that is a number, object, array or boolean: 400 `M_BAD_JSON`, the name is unchanged.
    * An unknown device, or a device of ANOTHER user: 404 `M_NOT_FOUND` (with or without a `display_name`), no row is created, nothing changes.
    * A stored `""` (non-NULL) counts as a name and survives `PUT {}`.
    * No access token: 401 `M_MISSING_TOKEN`.

  Real router, real database (`--include integration`). Sessions are legacy opaque sessions (`T.legacy_session!/3`) on a device row written the way the
  legacy login does it (`DeviceNameTestSupport.legacy_device!/3`).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [put_req_header: 3]

  alias Nebu.OAuth.DeviceNameTestSupport, as: D
  alias Nebu.OAuth.TestSupport, as: T

  @name "Work laptop"

  setup do
    env = D.setup_env!()
    uid = T.provision_user!()
    dev = D.device_id()
    D.legacy_device!(uid, dev, @name)
    s = T.legacy_session!(uid, dev)

    {:ok, Map.merge(env, %{uid: uid, dev: dev, at: s.at})}
  end

  # -- helpers -----------------------------------------------------------------

  defp path(device_id), do: "/_matrix/client/v3/devices/" <> URI.encode_www_form(device_id)

  defp put(at, device_id, body), do: T.matrix_request(:put, path(device_id), at, body: body)

  defp put!(ctx, body) do
    conn = put(ctx.at, ctx.dev, body)
    assert conn.status == 200, "PUT #{inspect(body)} must succeed, got #{conn.status}: #{conn.resp_body}"
    assert T.json(conn) == %{}, "a successful PUT returns an empty object"
    conn
  end

  # the `display_name` of the device in GET /devices (:absent when the key is missing)
  defp listed_name(ctx) do
    device = Enum.find(D.list_devices!(ctx.at), &(&1["device_id"] == ctx.dev)) || flunk("device #{ctx.dev} missing from GET /devices")
    Map.get(device, "display_name", :absent)
  end

  defp single_name(ctx), do: ctx.at |> D.get_device!(ctx.dev) |> Map.get("display_name", :absent)

  # the `unsigned` object of the device in POST /keys/query (the device needs published keys)
  defp keys_unsigned(ctx) do
    conn = T.matrix_request(:post, "/_matrix/client/v3/keys/query", ctx.at, body: %{"device_keys" => %{ctx.uid => []}})
    assert conn.status == 200, "keys/query must succeed, got #{conn.status}: #{conn.resp_body}"
    get_in(T.json(conn), ["device_keys", ctx.uid, ctx.dev, "unsigned"]) || flunk("keys/query shows no device_keys for #{ctx.dev}: #{conn.resp_body}")
  end

  defp assert_errcode!(conn, status, errcode) do
    assert conn.status == status, "expected #{status} #{errcode}, got #{conn.status}: #{conn.resp_body}"
    assert T.json(conn)["errcode"] == errcode
  end

  defp assert_name_everywhere!(ctx, name) do
    assert D.name_of(ctx.uid, ctx.dev) == name
    assert listed_name(ctx) == name, "GET /devices must show #{inspect(name)}"
    assert single_name(ctx) == name, "GET /devices/{id} must show #{inspect(name)}"
  end

  # -- PUT without display_name ------------------------------------------------

  # Scenario: PUT without display_name keeps the name
  @tag ac: "put-without-display-name-keeps-the-name"
  test "PUT {} -> 200 {} and the name is unchanged in the DB, GET /devices, GET /devices/{id} and keys/query", ctx do
    T.seed_device_keys!(ctx.uid, ctx.dev)
    assert keys_unsigned(ctx)["device_display_name"] == @name, "precondition: keys/query shows the name"

    put!(ctx, %{})

    assert_name_everywhere!(ctx, @name)
    assert keys_unsigned(ctx)["device_display_name"] == @name, "keys/query unsigned.device_display_name must still show the name"
  end

  @tag ac: "put-without-display-name-keeps-the-name"
  test "PUT {} keeps a stored blank name (\"\" is a name, not NULL)", ctx do
    blank_dev = D.device_id()
    D.legacy_device!(ctx.uid, blank_dev, "")
    assert D.name_of(ctx.uid, blank_dev) == "", "precondition: the stored name is the empty string"

    conn = put(ctx.at, blank_dev, %{})
    assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
    assert D.name_of(ctx.uid, blank_dev) == "", "PUT {} must not turn a stored \"\" into NULL"
  end

  @tag ac: "put-without-display-name-keeps-the-name"
  test "PUT with a name string still renames (regression)", ctx do
    put!(ctx, %{"display_name" => "My Laptop"})

    assert_name_everywhere!(ctx, "My Laptop")
  end

  # -- explicit null -----------------------------------------------------------

  # Scenario: An explicit JSON null clears the name
  @tag ac: "an-explicit-json-null-clears-the-name"
  test "PUT {\"display_name\": null} -> 200, the name is cleared (DB NULL, key absent in GET /devices, absent in keys/query)", ctx do
    T.seed_device_keys!(ctx.uid, ctx.dev)

    put!(ctx, %{"display_name" => nil})

    assert D.name_of(ctx.uid, ctx.dev) == nil
    assert listed_name(ctx) == :absent, "GET /devices must omit display_name after a null clear"
    assert single_name(ctx) == :absent, "GET /devices/{id} must omit display_name after a null clear"
    refute Map.has_key?(keys_unsigned(ctx), "device_display_name"), "keys/query must carry no device_display_name after a null clear"
  end

  # -- non-string display_name -------------------------------------------------

  # Scenario: A non-string display_name is rejected
  for {label, value} <- [number: 5, object: %{"a" => 1}, array: [], boolean: true] do
    @tag ac: "a-non-string-display-name-is-rejected"
    test "PUT {\"display_name\": <#{label}>} -> 400 M_BAD_JSON and the name is unchanged", ctx do
      conn = put(ctx.at, ctx.dev, %{"display_name" => unquote(Macro.escape(value))})

      assert_errcode!(conn, 400, "M_BAD_JSON")
      assert_name_everywhere!(ctx, @name)
    end
  end

  # -- unknown device ----------------------------------------------------------

  # Scenario: An unknown device is still 404
  @tag ac: "an-unknown-device-is-still-404"
  test "PUT {\"display_name\": \"x\"} on an unknown device -> 404 M_NOT_FOUND and no device row is created", ctx do
    unknown = D.device_id()

    assert_errcode!(put(ctx.at, unknown, %{"display_name" => "x"}), 404, "M_NOT_FOUND")
    assert D.device_row(ctx.uid, unknown) == nil, "a regular client must not create a device (no 201)"
  end

  @tag ac: "an-unknown-device-is-still-404"
  test "PUT {} on an unknown device -> 404 M_NOT_FOUND and no device row is created", ctx do
    unknown = D.device_id()

    assert_errcode!(put(ctx.at, unknown, %{}), 404, "M_NOT_FOUND")
    assert D.device_row(ctx.uid, unknown) == nil, "a regular client must not create a device (no 201)"
  end

  # -- another user's device ---------------------------------------------------

  @tag ac: "oracle-another-users-device-is-404"
  test "PUT with a name on ANOTHER user's device -> 404 M_NOT_FOUND and the name is unchanged", ctx do
    {foreign, foreign_dev} = foreign_device!("Bob's phone")

    assert_errcode!(put(ctx.at, foreign_dev, %{"display_name" => "Hijack"}), 404, "M_NOT_FOUND")
    assert D.name_of(foreign, foreign_dev) == "Bob's phone"
    assert D.name_of(ctx.uid, ctx.dev) == @name
  end

  @tag ac: "oracle-another-users-device-is-404"
  test "PUT {} and PUT null on ANOTHER user's device -> 404 M_NOT_FOUND and the name is unchanged", ctx do
    {foreign, foreign_dev} = foreign_device!("Bob's phone")

    assert_errcode!(put(ctx.at, foreign_dev, %{}), 404, "M_NOT_FOUND")
    assert_errcode!(put(ctx.at, foreign_dev, %{"display_name" => nil}), 404, "M_NOT_FOUND")
    assert D.name_of(foreign, foreign_dev) == "Bob's phone"
  end

  defp foreign_device!(name) do
    foreign = T.provision_user!()
    foreign_dev = D.device_id()
    D.legacy_device!(foreign, foreign_dev, name)
    {foreign, foreign_dev}
  end

  # -- auth --------------------------------------------------------------------

  @tag ac: "oracle-put-requires-an-access-token"
  test "PUT without an access token -> 401 M_MISSING_TOKEN and the name is unchanged", ctx do
    conn =
      conn(:put, path(ctx.dev), Jason.encode!(%{"display_name" => "Anon"}))
      |> put_req_header("content-type", "application/json")
      |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

    assert_errcode!(conn, 401, "M_MISSING_TOKEN")
    assert D.name_of(ctx.uid, ctx.dev) == @name
  end
end
