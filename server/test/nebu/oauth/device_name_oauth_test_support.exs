defmodule Nebu.OAuth.DeviceNameTestSupport do
  @moduledoc """
  Shared helpers of the tests of story `oauth-session-and-consent/oauth-device-default-display-name` (REQ-2026-004): the default display name of the
  device that an OAuth login creates.

  The FILE NAME ends with `oauth_test_support.exs` on purpose: `mix.exs` already ignores that suffix (`test_ignore_filters`), so no mix.exs change
  is needed (an unlisted support file in the test tree makes `mix test --warnings-as-errors` exit 1). Loaded once from `test/test_helper.exs`.
  Every function is `def` (no unused private helper per suite).

  ## The contract this story pins (names are the ATDD agent's; the dev may deviate only with a story Decisions note)

    * `Nebu.OAuth.DeviceName` (new, `lib/nebu/oauth/device_name.ex`; every call here goes through `apply/3` so the red state compiles under
      `--warnings-as-errors`):
        * `default_name(client_name, device_id) :: String.t()` (pure, never raises, any term): `"<base> (<suffix>)"`.
        * `for_client(client_id, device_id) :: String.t()` (one read of the client record, NEVER raises): the base is the `client_name` of an
          `approved` client; a revoked / pending / rejected / unknown client, a record without a usable name or an unreadable database give the plain
          base `"OAuth client"`.
        * `max_base_length/0` (= 64 code points) and `fallback_base/0` (= `"OAuth client"`).
    * Where it is applied: the token endpoint (`Nebu.OAuth.Token`) hands the name to the Matrix domain as an attribute of `Nebu.Matrix.oauth_issue_session/1`;
      `insert_replacing_device/1` writes it in the issuance transaction with `UPDATE devices SET display_name = $3 WHERE user_id = $1 AND device_id = $2
      AND display_name IS NULL`: it fills an UNSET name only, it never overwrites. No migration, no new column, no new log line.
  """
  import ExUnit.Assertions
  import Plug.Conn, only: [put_req_header: 3]

  alias Nebu.OAuth.TestSupport, as: T

  @mod Nebu.OAuth.DeviceName
  @fallback "OAuth client"
  @max_base 64
  @redirect "https://app.example.com/cb"

  def mod, do: @mod
  def fallback, do: @fallback
  def max_base, do: @max_base
  def redirect, do: @redirect

  # ── the module, through apply/3 ─────────────────────────────────────────────

  def call(fun, args) do
    assert Code.ensure_loaded?(@mod), "#{inspect(@mod)} does not exist yet (lib/nebu/oauth/device_name.ex)"
    assert function_exported?(@mod, fun, length(args)), "#{inspect(@mod)}.#{fun}/#{length(args)} is not defined"
    apply(@mod, fun, args)
  end

  def default_name(client_name, device_id), do: call(:default_name, [client_name, device_id])
  def for_client(client_id, device_id), do: call(:for_client, [client_id, device_id])

  @doc "The base part (without the ` (<suffix>)`) of a name made by `default_name/2`."
  def base_of(name) do
    assert name =~ ~r/ \([^()]*\)\z/, "the name must end with ' (<suffix>)', got #{inspect(name)}"
    String.replace(name, ~r/ \([^()]*\)\z/, "")
  end

  # ── environment ─────────────────────────────────────────────────────────────

  @doc """
  The OAuth switch + IdP stub + an approved client named `:client_name` (default `"FluffyChat"`; `nil` = a client without a name) with the redirect
  URI `#{@redirect}`. Registers every restore through `on_exit`. Returns `%{priv, cid}`.
  """
  def setup_env!(opts \\ []) do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    ExUnit.Callbacks.on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    cid = client!(Keyword.get(opts, :client_name, "FluffyChat"))
    %{priv: priv, cid: cid}
  end

  @doc "Another approved client with the redirect URI `#{@redirect}` (a `nil` name = no `client_name`)."
  def client!(client_name), do: T.oauth_client!([@redirect], client_name: client_name)

  # ── sessions through the real flow ──────────────────────────────────────────

  @doc """
  A live OAuth session (authorize -> IdP stub -> consent / remembered grant -> code -> token endpoint) on the chosen device id. Options: `:sub` (a fresh
  user), `:authorize` (more authorize overrides), `:idp_rt`. Returns the grant map of `T.session!/4` (`:at`, `:rt`, `:user_id`, `:device_id`, `:sub` ...).
  """
  def session!(cid, priv, device_id, opts \\ []) do
    authorize = Map.merge(%{"scope" => T.js_sdk_scope(device_id), "nonce" => "n-" <> T.rand()}, Map.new(Keyword.get(opts, :authorize, %{})))
    T.session!(cid, @redirect, priv, Keyword.merge([authorize: authorize], Keyword.take(opts, [:sub, :idp_rt, :claims])))
  end

  @doc "A device id that is unique per call (10 upper case characters, like Element's)."
  def device_id, do: "DN" <> String.upcase(T.rand(4))

  # ── device rows and the Matrix device API ───────────────────────────────────

  @doc "The `devices` row of `(user_id, device_id)` as a map, or nil."
  def device_row(user_id, device_id) do
    case T.sql!("SELECT * FROM devices WHERE user_id = $1 AND device_id = $2", [user_id, device_id]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  @doc "The stored display name of a device; flunks when there is no row."
  def name_of(user_id, device_id) do
    row = device_row(user_id, device_id) || flunk("no devices row for #{user_id} / #{device_id}")
    row["display_name"]
  end

  @doc "All stored display names of a user's devices, `%{device_id => name}`."
  def names_of(user_id) do
    %{rows: rows} = T.sql!("SELECT device_id, display_name FROM devices WHERE user_id = $1 ORDER BY device_id", [user_id])
    Map.new(rows, fn [d, n] -> {d, n} end)
  end

  @doc "A device row written the way the legacy login does it (`DeviceKeyStore.upsert_device/3`), with a stored name or none."
  def legacy_device!(user_id, device_id, display_name) do
    :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(user_id, device_id, display_name: display_name, last_seen_ts: System.system_time(:millisecond))
  end

  @doc "`PUT /_matrix/client/v3/devices/{id}` with a bearer token (the client's own naming of its device)."
  def put_name(at, device_id, display_name),
    do: T.matrix_request(:put, "/_matrix/client/v3/devices/" <> URI.encode_www_form(device_id), at, body: %{"display_name" => display_name})

  def put_name!(at, device_id, display_name) do
    conn = put_name(at, device_id, display_name)
    assert conn.status == 200, "PUT /devices/#{device_id} must succeed, got #{conn.status}: #{conn.resp_body}"
    :ok
  end

  @doc "`PUT /devices/{id}` WITHOUT `display_name`: the client clears the name (the handler stores NULL)."
  def clear_name!(at, device_id) do
    conn = T.matrix_request(:put, "/_matrix/client/v3/devices/" <> URI.encode_www_form(device_id), at, body: %{})
    assert conn.status == 200, "PUT /devices/#{device_id} without display_name must succeed, got #{conn.status}: #{conn.resp_body}"
    :ok
  end

  @doc "`GET /_matrix/client/v3/devices` of the token's user: the decoded device list."
  def list_devices!(at) do
    conn = T.matrix_request(:get, "/_matrix/client/v3/devices", at)
    assert conn.status == 200, "GET /devices must succeed, got #{conn.status}: #{conn.resp_body}"
    T.json(conn)["devices"]
  end

  def get_device!(at, device_id) do
    conn = T.matrix_request(:get, "/_matrix/client/v3/devices/" <> URI.encode_www_form(device_id), at)
    assert conn.status == 200, "GET /devices/#{device_id} must succeed, got #{conn.status}: #{conn.resp_body}"
    T.json(conn)
  end

  # ── the legacy login (raw JWT in `m.login.token`, the path a legacy / SSO client uses) ──────────

  @doc """
  `POST /login` with `m.login.token` carrying a raw IdP JWT of `sub` (the real `HttpPublic` login path, `register_device/4`), optionally with
  `initial_device_display_name` and a client-chosen `device_id`. Returns the conn.
  """
  def legacy_login(priv, sub, opts \\ []) do
    jwt = T.sign_id_token(priv, %{"sub" => sub, "exp" => System.system_time(:second) + 3600, "jti" => "atdd-dn-" <> T.rand()})

    body =
      %{"type" => "m.login.token", "token" => jwt}
      |> put_if("device_id", opts[:device_id])
      |> put_if("initial_device_display_name", opts[:initial_device_display_name])

    Plug.Test.conn(:post, "/_matrix/client/v3/login", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Map.put(:remote_ip, T.unique_ip())
    |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # ── hostile text ────────────────────────────────────────────────────────────

  @doc "True when `text` carries a control, format, line / paragraph separator, private-use or surrogate code point, or markup characters."
  def hostile?(text) when is_binary(text), do: Regex.match?(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cs}<>]/u, text)

  @doc "The number of Unicode code points of `text`."
  def codepoints(text), do: text |> String.codepoints() |> length()
end
