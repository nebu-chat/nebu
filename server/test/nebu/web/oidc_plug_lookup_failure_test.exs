defmodule Nebu.Web.OidcPlugLookupFailureTest do
  @moduledoc """
  Acceptance tests for the bugfix `matrix-token-lookup-db-error-not-401`.

  A database failure while looking up an opaque access token must answer a retryable
  `503 M_UNKNOWN` (+ `Retry-After`), never `401 M_UNKNOWN_TOKEN` (which makes a Matrix client drop the
  session and its E2EE keys). Genuinely unknown / superseded / expired tokens keep their 401 answers.

  ## Fault injection contract (implemented by the dev step, MUST exist for these tests to pass)

  A compile-time guarded (`Mix.env() == :test`) seam in
  `Nebu.Matrix.Session.MatrixSessionStore.get_by_access_token_hash/1` reads
  `Application.get_env(:nebu_http, :matrix_session_lookup_fault)`:

    * `{:error, term}` - used as the query result (a DB error)
    * `:raise`         - raises `%DBConnection.ConnectionError{}`
    * `:exit`          - exits like a pool checkout timeout
    * unset            - normal behaviour

  The fault term / exception message carries a SENTINEL string that must never reach the log or a response.

  ## Layout

  Tests that need no database (the fault comes before the query, a missing header never reaches the store)
  run in the unit suite. Tests that need a real `matrix_sessions` row or a real "no row" answer are tagged
  `:integration` (`make test-integration`).

  Requests go through the real `Nebu.Web.Router`, which forwards to `Router.Protected` (client routes),
  `Router.Media` (`/_matrix/media/v3`) and `Router.ClientV1Media` (`/_matrix/client/v1/media`); all three run
  the shared `OidcPlug`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

  @router_opts Nebu.Web.Router.init([])
  @fault_key :matrix_session_lookup_fault
  @sentinel "SENTINEL-SECRET-DB-ERR"

  @whoami "/_matrix/client/v3/account/whoami"
  @client_v1_media "/_matrix/client/v1/media/download/test.local/someMediaId"
  @media_v3 "/_matrix/media/v3/download/test.local/someMediaId"
  @routes [@whoami, @client_v1_media, @media_v3]

  setup do
    prior_server_name = Application.fetch_env(:nebu_http, :server_name)
    Application.put_env(:nebu_http, :server_name, "test.local")
    prior_level = Logger.level()

    on_exit(fn ->
      Application.delete_env(:nebu_http, @fault_key)
      Logger.configure(level: prior_level)

      case prior_server_name do
        {:ok, value} -> Application.put_env(:nebu_http, :server_name, value)
        :error -> Application.delete_env(:nebu_http, :server_name)
      end
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp faults do
    [
      {:error, %DBConnection.ConnectionError{message: @sentinel}},
      {:error, :repo_not_started},
      {:error, {:sentinel, @sentinel}},
      :raise,
      :exit
    ]
  end

  defp set_fault(fault), do: Application.put_env(:nebu_http, @fault_key, fault)
  defp clear_fault, do: Application.delete_env(:nebu_http, @fault_key)

  defp opaque, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp unique_user, do: "@lookupfail_#{System.unique_integer([:positive])}:test.local"
  defp unique_device, do: "LFDEV#{System.unique_integer([:positive])}"

  defp get_with(path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Router.call(@router_opts)
  end

  defp get_without_token(path), do: conn(:get, path) |> Nebu.Web.Router.call(@router_opts)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> List.first() |> to_string()

  # The complete contract of the retryable lookup failure (AC1 + AC6).
  defp assert_lookup_unavailable(conn, label) do
    assert conn.status == 503, "#{label}: expected 503, got #{conn.status} #{conn.resp_body}"
    assert conn.halted, "#{label}: conn must be halted (fail closed)"
    assert content_type(conn) =~ "application/json", "#{label}: JSON content type"

    decoded = body(conn)
    assert decoded["errcode"] == "M_UNKNOWN", "#{label}: #{conn.resp_body}"
    assert is_binary(decoded["error"]) and decoded["error"] != ""
    refute Map.has_key?(decoded, "soft_logout")
    refute Map.has_key?(decoded, "retry_after_ms")
    refute conn.resp_body =~ "M_UNKNOWN_TOKEN"

    assert [retry_after] = get_resp_header(conn, "retry-after"), "#{label}: Retry-After header"
    assert {seconds, ""} = Integer.parse(retry_after)
    assert seconds > 0

    refute Map.has_key?(conn.assigns, :current_user), "#{label}: not authenticated"
    refute Map.has_key?(conn.assigns, :access_token), "#{label}: no token assigned"
    refute Map.has_key?(decoded, "user_id"), "#{label}: handler must not have run"
    conn
  end

  defp assert_no_secrets(conn, secrets) do
    headers = conn.resp_headers |> Enum.map(fn {k, v} -> k <> ": " <> v end) |> Enum.join("\n")

    for secret <- secrets do
      refute conn.resp_body =~ secret
      refute headers =~ secret
    end

    refute conn.resp_body =~ "SENTINEL"
    refute headers =~ "SENTINEL"
  end

  # DB-backed fixtures (integration only) ------------------------------------

  defp create_session(opts \\ []) do
    token = opaque()
    user_id = Keyword.get(opts, :user_id, unique_user())
    device_id = Keyword.get(opts, :device_id, unique_device())
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 3600, :second))

    :ok =
      Store.create(%{
        access_token: token,
        refresh_token: opaque(),
        user_id: user_id,
        device_id: device_id,
        expires_at: expires_at
      })

    on_exit(fn ->
      Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM matrix_sessions WHERE user_id = $1", [user_id])
    end)

    %{token: token, user_id: user_id, device_id: device_id}
  end

  defp supersede(token) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "UPDATE matrix_sessions SET revoked_at = NOW() WHERE access_token_hash = $1",
        [Store.hash_token(token)]
      )

    :ok
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1: a failed lookup is a retryable server error (no database needed)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1 failed token lookup is 503 M_UNKNOWN, not 401" do
    @tag ac: "a-failed-token-lookup-is-a-retryable-server-error-not-a-session-drop"
    test "AC1: every fault form on the client route (whoami) answers 503 M_UNKNOWN + Retry-After" do
      for fault <- faults() do
        set_fault(fault)
        conn = get_with(@whoami, opaque())
        assert_lookup_unavailable(conn, "whoami #{inspect(fault)}")
      end
    end

    @tag ac: "a-failed-token-lookup-is-a-retryable-server-error-not-a-session-drop"
    test "AC1: every fault form on the media routes answers 503 M_UNKNOWN + Retry-After" do
      for path <- [@client_v1_media, @media_v3], fault <- faults() do
        set_fault(fault)
        conn = get_with(path, opaque())
        assert_lookup_unavailable(conn, "#{path} #{inspect(fault)}")
      end
    end

    @tag ac: "a-failed-token-lookup-is-a-retryable-server-error-not-a-session-drop"
    test "AC1: the lookup failure never authenticates and never runs the handler (whoami body has no user_id)" do
      set_fault({:error, :repo_not_started})
      conn = get_with(@whoami, opaque())

      assert conn.status == 503
      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :device_id)
      refute conn.resp_body =~ "is_guest"
    end

    @tag ac: "a-failed-token-lookup-is-a-retryable-server-error-not-a-session-drop"
    test "AC1/AC5: the 503 body and headers contain neither the token nor its hash" do
      token = opaque()
      hash = Store.hash_token(token)

      for fault <- faults(), path <- @routes do
        set_fault(fault)
        conn = get_with(path, token)
        assert conn.status == 503
        assert_no_secrets(conn, [token, hash])
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6: a lookup failure is not a token oracle (no database needed)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6 lookup failure is not a token oracle" do
    @tag ac: "a-lookup-failure-is-not-a-token-oracle"
    test "AC6: unknown (random 64 hex) tokens get the same 503 under every fault form on every route" do
      for fault <- faults(), path <- @routes do
        set_fault(fault)
        conn = get_with(path, opaque())
        assert_lookup_unavailable(conn, "unknown token #{path} #{inspect(fault)}")
      end
    end

    @tag ac: "a-lookup-failure-is-not-a-token-oracle"
    test "AC6: malformed opaque tokens (non-hex, short, long) get the same 503 as well" do
      for fault <- faults(), token <- ["not-hex-at-all-zzzz", "abc", String.duplicate("g", 64), String.duplicate("a", 200)] do
        set_fault(fault)
        conn = get_with(@whoami, token)
        assert_lookup_unavailable(conn, "malformed #{inspect(token)} #{inspect(fault)}")
      end
    end

    @tag ac: "a-lookup-failure-is-not-a-token-oracle"
    test "AC6: the 503 answer is byte-identical for different tokens (no token-dependent text)" do
      set_fault(:raise)
      a = get_with(@whoami, opaque())
      b = get_with(@whoami, opaque())
      c = get_with(@whoami, "short")

      assert a.status == 503
      assert a.resp_body == b.resp_body
      assert a.resp_body == c.resp_body
      assert get_resp_header(a, "retry-after") == get_resp_header(b, "retry-after")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Oracle: missing token (no DB call)
  # ══════════════════════════════════════════════════════════════════════════

  describe "missing token" do
    @tag ac: "a-genuinely-unknown-token-is-still-rejected-with-401-m-unknown-token"
    test "oracle: a request without Authorization is 401 M_MISSING_TOKEN, even while the lookup is faulted" do
      set_fault({:error, :repo_not_started})

      for path <- @routes do
        conn = get_without_token(path)
        assert conn.status == 401
        assert conn.halted
        assert content_type(conn) =~ "application/json"
        assert %{"errcode" => "M_MISSING_TOKEN", "error" => error} = body(conn)
        assert is_binary(error)
        refute Map.has_key?(body(conn), "soft_logout")
        assert get_resp_header(conn, "retry-after") == []
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5: the failure is logged without sensitive data (valid row needs the DB)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5 log hygiene (DB-backed: real session row)" do
    @describetag :integration

    @tag ac: "the-failure-is-logged-without-sensitive-data"
    test "AC5: a faulted lookup logs at most one redacted line (no token, hash, user, device, SQL, exception text)" do
      sess = create_session()
      hash = Store.hash_token(sess.token)

      # the failure warning is rate limited (1/min/node); disable the limiter so that EVERY request writes its line
      prior_limit = Application.fetch_env(:nebu_http, :rate_limit_disabled)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      on_exit(fn ->
        case prior_limit do
          {:ok, v} -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
          :error -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        end
      end)

      expected_class = fn
        {:error, %DBConnection.ConnectionError{}} -> "DBConnection.ConnectionError"
        {:error, :repo_not_started} -> "repo_not_started"
        {:error, {:sentinel, _}} -> "unknown"
        :raise -> "DBConnection.ConnectionError"
        :exit -> "exit_timeout"
      end

      for fault <- faults() do
        set_fault(fault)
        Logger.configure(level: :debug)

        {conn, log} =
          with_log([level: :debug], fn -> get_with(@whoami, sess.token) end)

        assert conn.status == 503

        for secret <- [sess.token, hash, sess.user_id, sess.device_id, "SENTINEL", "SELECT", "matrix_sessions"] do
          refute log =~ secret, "log leaked #{inspect(secret)} for #{inspect(fault)}:\n#{log}"
        end

        failure_lines =
          log
          |> String.split("\n", trim: true)
          |> Enum.filter(&(&1 =~ ~r/access token lookup/))

        assert length(failure_lines) <= 1,
               "expected at most one failure log line for #{inspect(fault)}, got:\n#{Enum.join(failure_lines, "\n")}"

        # the one line names ONLY the redacted error class
        assert log =~ "access token lookup unavailable class=#{expected_class.(fault)}\n",
               "expected the redacted class line for #{inspect(fault)}, got:\n#{log}"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # DB-backed behaviour (real session rows)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1 valid token + fault (DB-backed: real session row)" do
    @describetag :integration

    @tag ac: "a-failed-token-lookup-is-a-retryable-server-error-not-a-session-drop"
    test "AC1: a VALID token under every fault form answers 503 (not 401, no soft_logout), also on the media routes" do
      sess = create_session()

      for path <- @routes, fault <- faults() do
        set_fault(fault)
        conn = get_with(path, sess.token)
        assert_lookup_unavailable(conn, "valid token #{path} #{inspect(fault)}")
        assert_no_secrets(conn, [sess.token, Store.hash_token(sess.token), sess.user_id, sess.device_id])
      end
    end

    @tag ac: "a-failed-token-lookup-is-a-retryable-server-error-not-a-session-drop"
    test "AC1: once the fault is gone the same valid token authenticates again (the session was not touched)" do
      sess = create_session()

      set_fault(:raise)
      assert get_with(@whoami, sess.token).status == 503

      clear_fault()
      conn = get_with(@whoami, sess.token)
      assert conn.status == 200
      assert body(conn)["user_id"] == sess.user_id
    end
  end

  describe "AC2/AC3/AC4 unchanged answers without a fault (DB-backed)" do
    @describetag :integration

    @tag ac: "a-genuinely-unknown-token-is-still-rejected-with-401-m-unknown-token"
    test "AC2: an unknown opaque token is 401 M_UNKNOWN_TOKEN without soft_logout on every route" do
      clear_fault()

      for path <- @routes do
        conn = get_with(path, opaque())
        assert conn.status == 401
        assert conn.halted
        assert content_type(conn) =~ "application/json"
        decoded = body(conn)
        assert decoded["errcode"] == "M_UNKNOWN_TOKEN"
        assert decoded["error"] == "Invalid or unknown token"
        refute Map.has_key?(decoded, "soft_logout")
        assert get_resp_header(conn, "retry-after") == []
      end
    end

    @tag ac: "a-valid-token-is-still-accepted"
    test "AC3: a valid token is authenticated (200) and whoami returns the right user and device" do
      sess = create_session()
      clear_fault()

      conn = get_with(@whoami, sess.token)
      assert conn.status == 200
      assert %{"user_id" => user_id, "device_id" => device_id} = body(conn)
      assert user_id == sess.user_id
      assert device_id == sess.device_id
      assert conn.assigns[:current_user] == sess.user_id
    end

    @tag ac: "superseded-and-expired-tokens-keep-their-answers"
    test "AC4: a superseded (revoked_at set) session is 401 M_UNKNOWN_TOKEN with soft_logout true" do
      sess = create_session()
      :ok = supersede(sess.token)
      clear_fault()

      for path <- @routes do
        conn = get_with(path, sess.token)
        assert conn.status == 401
        assert %{"errcode" => "M_UNKNOWN_TOKEN", "soft_logout" => true} = body(conn)
      end
    end

    @tag ac: "superseded-and-expired-tokens-keep-their-answers"
    test "AC4: an expired session is 401 M_UNKNOWN_TOKEN with soft_logout true" do
      sess = create_session(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      clear_fault()

      for path <- @routes do
        conn = get_with(path, sess.token)
        assert conn.status == 401
        assert %{"errcode" => "M_UNKNOWN_TOKEN", "soft_logout" => true} = body(conn)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Store level
  # ══════════════════════════════════════════════════════════════════════════

  describe "store: lookup result shape" do
    @tag ac: "a-failed-token-lookup-is-a-retryable-server-error-not-a-session-drop"
    test "get_by_access_token/1 and get_by_access_token_hash/1 return {:error, :unavailable} under every fault form" do
      token = opaque()

      for fault <- faults() do
        set_fault(fault)

        assert Store.get_by_access_token(token) == {:error, :unavailable}, "token lookup #{inspect(fault)}"
        assert Store.get_by_access_token_hash(Store.hash_token(token)) == {:error, :unavailable}, "hash lookup #{inspect(fault)}"
      end
    end

    @tag ac: "a-valid-token-is-still-accepted"
    @tag :integration
    test "without a fault: :error for an unknown token, {:ok, session} for a valid one" do
      sess = create_session()
      clear_fault()

      assert Store.get_by_access_token(opaque()) == :error
      assert Store.get_by_access_token_hash(Store.hash_token(opaque())) == :error

      assert {:ok, %{user_id: user_id, device_id: device_id}} = Store.get_by_access_token(sess.token)
      assert user_id == sess.user_id
      assert device_id == sess.device_id

      assert {:ok, %{user_id: ^user_id}} = Store.get_by_access_token_hash(Store.hash_token(sess.token))
    end
  end
end
