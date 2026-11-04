defmodule Nebu.Matrix.RoomKeysTestSupport do
  @moduledoc """
  Shared helpers of the suites of story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011): Matrix CS v1.18 "Server-side key backups"
  (`/_matrix/client/v3/room_keys/**`), the opaque per-user key backup store.

  Loaded once from `test_helper.exs` (like the other support modules); every function is `def`. The FILE NAME ends with `oauth_test_support.exs` on purpose:
  `mix.exs` already ignores that suffix (`test_ignore_filters`), so no mix.exs edit is needed (a support file the filters do not know makes
  `mix test --warnings-as-errors` exit 1 with "files do not match any of the configured :test_load_filters").

  ## The contract the suites pin (decisions of the ATDD step; the oracle context of the story is the spec side)

    * Tables (names are pinned because the GDPR erasure inventory and the migration tests name them): `room_key_backup_versions` and `room_key_backup_sessions`, both with
      a `user_id TEXT NOT NULL` column (the erasure deletes `WHERE user_id = $1`).
    * A version is a string of decimal digits without a leading zero, strictly increasing per user (the newest non-deleted version is the CURRENT one).
    * Errors: a missing required body member / query parameter is `400 M_MISSING_PARAM`, a member of the wrong type or value `400 M_INVALID_PARAM`, a body that is
      not JSON `400 M_NOT_JSON`, JSON that is not an object `400 M_BAD_JSON`; an oversize `session_data` / `auth_data` / request body is `413 M_TOO_LARGE`; a quota
      (11th version, session cap of a version) is `403 M_FORBIDDEN`.
    * Sizes are measured as the byte size of the canonical (compact) JSON encoding of the value: `session_data` <= 8 KiB, `auth_data` <= 16 KiB,
      request body <= 5 MiB on every `room_keys` route.
    * Seam: `Application.get_env(:nebu, :room_keys_max_sessions_per_version, 100_000)` is read at REQUEST time (the tests lower it).
  """
  import ExUnit.Assertions
  import Plug.Conn
  import Plug.Test

  alias Nebu.OAuth.TestSupport, as: T

  @router_opts Nebu.Web.Router.init([])
  @prefix "/_matrix/client/v3/room_keys"
  @algorithm "m.megolm_backup.v1.curve25519-aes-sha2"
  @versions_table "room_key_backup_versions"
  @sessions_table "room_key_backup_sessions"

  def algorithm, do: @algorithm
  def prefix, do: @prefix
  def versions_table, do: @versions_table
  def sessions_table, do: @sessions_table
  def max_versions, do: 10
  def max_session_data_bytes, do: 8 * 1024
  def max_auth_data_bytes, do: 16 * 1024
  def max_body_bytes, do: 5 * 1024 * 1024
  def max_sessions_per_version, do: 100_000
  # cycle 2: the default byte budget of a user (64 MiB), the fixed byte cost of a stored session row besides its `session_data`
  # (the room_id and session_id bytes are counted on top), and the default node-wide cap of bulk reads in flight
  def default_max_bytes, do: 64 * 1024 * 1024
  def row_overhead, do: 128
  def default_bulk_reads_per_node, do: 2

  @doc "What one stored session row costs the byte budget: octet_length(room_id) + octet_length(session_id) + 128 + the canonical bytes of its session_data."
  def session_cost(room_id, session_id, data_bytes), do: byte_size(room_id) + byte_size(session_id) + row_overhead() + data_bytes

  # ── users, requests ─────────────────────────────────────────────────────────

  @doc "A provisioned user with a legacy opaque session. Returns `%{uid, at}`."
  def user! do
    uid = T.provision_user!()
    %{at: at} = T.legacy_session!(uid, "RK" <> String.upcase(T.rand(4)))
    %{uid: uid, at: at}
  end

  @doc """
  One request through the full `Nebu.Web.Router`. `token` nil = no Authorization header. `body`: nil | a term (JSON-encoded) | `{:raw, binary}` (verbatim bytes,
  `application/json`). Every request has its own peer address (no shared per-IP bucket).
  """
  def req(method, path, token, body \\ nil) do
    c =
      case body do
        nil -> conn(method, path)
        {:raw, raw} -> conn(method, path, raw) |> put_req_header("content-type", "application/json")
        term -> conn(method, path, Jason.encode!(term)) |> put_req_header("content-type", "application/json")
      end

    c = put_auth(c, token)
    Nebu.Web.Router.call(%{c | remote_ip: T.unique_ip()}, @router_opts)
  end

  # token: nil (no header) | a bearer token | `{:header, value}` (the Authorization header verbatim, e.g. "Basic abc")
  defp put_auth(c, nil), do: c
  defp put_auth(c, {:header, value}), do: put_req_header(c, "authorization", value)
  defp put_auth(c, token), do: put_req_header(c, "authorization", "Bearer " <> token)

  @doc "A request with verbatim body bytes and a chosen content type (nil = none)."
  def req_ct(method, path, token, raw, content_type) do
    c = conn(method, path, raw)
    c = if content_type, do: put_req_header(c, "content-type", content_type), else: c
    c = put_auth(c, token)
    Nebu.Web.Router.call(%{c | remote_ip: T.unique_ip()}, @router_opts)
  end

  def json(conn), do: T.json(conn)

  @doc "A path segment, percent-encoded (everything except the unreserved characters)."
  def seg(s), do: URI.encode(s, &URI.char_unreserved?/1)

  def version_path(version \\ nil), do: if(version, do: "#{@prefix}/version/#{seg(version)}", else: "#{@prefix}/version")

  @doc "`/room_keys/keys[/{room}[/{session}]]` with `?version=` (nil = no query, `\"\"` = an empty value)."
  def keys_path(version, room \\ nil, session \\ nil) do
    base =
      cond do
        room == nil -> "#{@prefix}/keys"
        session == nil -> "#{@prefix}/keys/#{seg(room)}"
        true -> "#{@prefix}/keys/#{seg(room)}/#{seg(session)}"
      end

    if version == nil, do: base, else: base <> "?version=" <> URI.encode_www_form(version)
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  def auth_data(tag \\ "ad") do
    %{"public_key" => "pk-" <> tag, "signatures" => %{"@signer:test.local" => %{"ed25519:DEV" => "sig-" <> tag}}}
  end

  @doc "A KeyBackupData. `data` = the session_data object (default: a small object tagged with the numbers, so every variant is distinguishable)."
  def kbd(first_message_index, forwarded_count, verified?, data \\ nil) do
    %{
      "first_message_index" => first_message_index,
      "forwarded_count" => forwarded_count,
      "is_verified" => verified?,
      "session_data" => data || %{"ephemeral" => "eph-#{first_message_index}-#{forwarded_count}-#{verified?}", "ciphertext" => "ct", "mac" => "mac"}
    }
  end

  @doc "A session_data object whose canonical (compact) JSON encoding is EXACTLY `bytes` bytes long (`{\"k\":\"aaa...\"}`: 8 bytes of overhead)."
  def sized_data(bytes) when bytes >= 8, do: %{"k" => String.duplicate("a", bytes - 8)}

  @doc "The same with `n` bytes of 2-byte characters: `2n + 8` bytes (a character count under the limit, a byte count over it)."
  def sized_data_multibyte(n), do: %{"k" => String.duplicate("é", n)}

  def canonical_size(term), do: byte_size(Jason.encode!(term))

  # ── calls ───────────────────────────────────────────────────────────────────

  @doc "POST /version; asserts 200 and returns the version string. Accepts a user map or an access token."
  def create!(user_or_at, ad \\ nil) do
    at = if is_map(user_or_at), do: user_or_at.at, else: user_or_at
    c = req(:post, version_path(), at, %{"algorithm" => @algorithm, "auth_data" => ad || auth_data()})
    assert c.status == 200, "POST /room_keys/version: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    assert %{"version" => version} = json(c)
    assert is_binary(version) and version =~ ~r/\A[1-9][0-9]*\z/, "a version is a decimal string without a leading zero, got #{inspect(version)}"
    version
  end

  def post_version(at, body), do: req(:post, version_path(), at, body)
  def get_version(at, version \\ nil), do: req(:get, version_path(version), at)
  def put_version(at, version, body), do: req(:put, version_path(version), at, body)
  def delete_version(at, version), do: req(:delete, version_path(version), at)

  def get_keys(at, version, room \\ nil, session \\ nil), do: req(:get, keys_path(version, room, session), at)
  def delete_keys(at, version, room \\ nil, session \\ nil), do: req(:delete, keys_path(version, room, session), at)

  @doc "PUT /keys?version= with `%{room => %{session => kbd}}`."
  def put_rooms(at, version, rooms) when is_map(rooms) do
    req(:put, keys_path(version), at, %{"rooms" => Map.new(rooms, fn {room, sessions} -> {room, %{"sessions" => sessions}} end)})
  end

  @doc "PUT /keys?version= with the verbatim body bytes."
  def put_keys_raw(at, version, raw) when is_binary(raw), do: req(:put, keys_path(version), at, {:raw, raw})

  @doc "PUT /keys/{room}?version= with `%{session => kbd}`."
  def put_room(at, version, room, sessions), do: req(:put, keys_path(version, room), at, %{"sessions" => sessions})

  @doc "PUT /keys/{room}/{session}?version= with one kbd."
  def put_session(at, version, room, session, kbd), do: req(:put, keys_path(version, room, session), at, kbd)

  @doc "Asserts a 200 `{count, etag}` answer of a key write / delete and returns `{count, etag}`."
  def count_etag!(conn) do
    assert conn.status == 200, "expected 200 {count, etag}, got #{conn.status} #{String.slice(conn.resp_body, 0, 300)}"
    body = json(conn)
    assert Enum.sort(Map.keys(body)) == ["count", "etag"], "exactly count and etag, got #{inspect(Map.keys(body))}"
    assert is_integer(body["count"]) and body["count"] >= 0
    assert is_binary(body["etag"]) and body["etag"] != ""
    {body["count"], body["etag"]}
  end

  @doc "The info of a version as `%{count, etag, ...}` (asserts 200)."
  def info!(at, version \\ nil) do
    c = get_version(at, version)
    assert c.status == 200, "GET /room_keys/version#{if version, do: "/" <> version}: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    json(c)
  end

  @doc "`%{{room, session} => kbd}` of GET /keys?version= (asserts 200)."
  def sessions!(at, version) do
    c = get_keys(at, version)
    assert c.status == 200, "GET /room_keys/keys: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    %{"rooms" => rooms} = json(c)

    for {room, %{"sessions" => sessions}} <- rooms, {sid, kbd} <- sessions, into: %{}, do: {{room, sid}, kbd}
  end

  def assert_error(conn, status, errcode) do
    assert conn.status == status, "expected #{status} #{errcode}, got #{conn.status} #{String.slice(conn.resp_body || "", 0, 300)}"
    body = json(conn)
    assert body["errcode"] == errcode, "expected errcode #{errcode}, got #{inspect(body)}"
    assert is_binary(body["error"]) and body["error"] != "", "a Matrix error carries a human readable `error`"
    assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}
    body
  end

  # ── database probes (runtime role) ──────────────────────────────────────────

  def rows(table, uid), do: T.sql!("SELECT count(*) FROM #{table} WHERE user_id = $1", [uid]).rows |> hd() |> hd()

  @doc "The whole stored rows of the user as one text (`t::text`): what a canary can hide in."
  def row_text(table, uid) do
    %{rows: [[text]]} = T.sql!("SELECT COALESCE(string_agg(t::text, E'\\n'), '') FROM #{table} t WHERE t.user_id = $1", [uid])
    text
  end

  # ── environment ─────────────────────────────────────────────────────────────

  def put_env_restoring(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  def disable_rate_limit, do: put_env_restoring(:nebu_http, :rate_limit_disabled, true)

  @doc "The real limiter with a frozen clock (no refill: a burst is deterministic); the harness OS variable is neutralised and restored."
  def enable_rate_limit do
    prev_env = System.get_env("NEBU_RATE_LIMIT_DISABLED")
    System.delete_env("NEBU_RATE_LIMIT_DISABLED")
    ExUnit.Callbacks.on_exit(fn -> if prev_env, do: System.put_env("NEBU_RATE_LIMIT_DISABLED", prev_env) end)
    put_env_restoring(:nebu_http, :rate_limit_clock_fn, fn -> 5_000_000 end)
    put_env_restoring(:nebu_http, :rate_limit_disabled, false)
    T.reset_rate_limits()
    ExUnit.Callbacks.on_exit(&T.restore_rate_limits/0)
  end

  @doc "Freezes the rate-limit clock at `ms` (a limiter enabled with `enable_rate_limit/0` refills linearly from the frozen instants); restored by its `on_exit`."
  def set_clock(ms), do: Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> ms end)

  @doc """
  Runs the request `fun` like a well-behaved client: a `429 M_LIMIT_EXCEEDED` is retried (after a short pause) until another answer comes, at most
  `attempts` times. Cycle 2: a writer that finds the per-user lock busy is answered 429 at once (a try-lock), so tests that fire concurrent writes of ONE
  user and assert the final state use this to see the answer the request would have had without the contention.
  """
  def retrying(fun, attempts \\ 400) do
    conn = fun.()

    if attempts > 1 and conn.status == 429 and json(conn)["errcode"] == "M_LIMIT_EXCEEDED" do
      Process.sleep(Enum.random(2..15))
      retrying(fun, attempts - 1)
    else
      conn
    end
  end

  def with_log_level(level, fun) do
    original = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original)
    end
  end

  # ── seeding for the GDPR erasure inventory ──────────────────────────────────

  @doc """
  Seeds the key backup of `uid` through the REAL routes (a temporary legacy session of the seeded device `dev`; the session row is removed again so the
  teardown tables of the erasure inventory are exactly as before): an older version with one stored session, the current version with sessions in two rooms
  and a third version that is deleted again at once (the soft-delete marker; the second one stays the current one). Every blob carries `canary`.
  Returns `%{older, current, deleted}`.

  Cycle 2: the seeding is SIX writes of one user and the write bucket now has a burst of 5, while the erasure suites run with the real limiter
  (`E.setup_env!`): the limiter is switched OFF for the duration of the seeding (`:nebu_http, :rate_limit_disabled`, restored afterwards), so a seed is
  never a 429 and the erasure suites do not depend on the limiter numbers.
  """
  def seed_backup!(uid, dev, canary) do
    %{at: at} = T.legacy_session!(uid, dev)
    prev_disabled = Application.fetch_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    r1 = "!seed-r1-#{canary}:test.local"
    r2 = "!seed-r2-#{canary}:test.local"

    try do
      older = create!(at, auth_data("old-" <> canary))
      count_etag!(put_session(at, older, r1, "sess-o-#{canary}", kbd(0, 0, false, %{"ciphertext" => "ct-old-#{canary}"})))
      current = create!(at, auth_data("cur-" <> canary))

      count_etag!(
        put_rooms(at, current, %{
          r1 => %{"sess-c1-#{canary}" => kbd(1, 0, true, %{"ciphertext" => "ct-c1-#{canary}"})},
          r2 => %{"sess-c2-#{canary}" => kbd(2, 1, false, %{"ciphertext" => "ct-c2-#{canary}"})}
        })
      )

      deleted = create!(at, auth_data("del-" <> canary))
      assert delete_version(at, deleted).status == 200
      %{older: older, current: current, deleted: deleted}
    rescue
      e in ExUnit.AssertionError ->
        msg = "RoomKeysTestSupport.seed_backup! (called by UserDeletionTestSupport.seed_user!/2: every erasure suite seeds a key backup through the room_keys routes of story server-side-key-backup) failed: "
        reraise %{e | message: msg <> e.message}, __STACKTRACE__
    after
      case prev_disabled do
        {:ok, v} -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        :error -> Application.delete_env(:nebu_http, :rate_limit_disabled)
      end

      T.sql!("DELETE FROM matrix_sessions WHERE access_token_hash = $1", [T.token_hash(at)])
    end
  end
end
