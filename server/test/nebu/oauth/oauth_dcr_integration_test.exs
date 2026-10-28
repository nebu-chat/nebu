defmodule Nebu.OAuth.OAuthDcrIntegrationTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `oauth-metadata-dcr-admin-approval`:

    * AC2 — successful Dynamic Client Registration (201, filtered response, defaults)
    * AC3 — metadata_hash deduplication (identical => same client_id, one row; key order and
            `#lang` keys ignored; concurrent registrations; rejected stays rejected)
    * AC4 — every new registration starts `pending` (no auto-approval)
    * AC5 — what gets stored in `oauth_clients`
    * AC7 — INFO logs carry client_id + metadata_hash but never the full metadata; DEBUG logs
            never expose secrets

  Tagged `:integration` — run with `mix test --include integration`. Requires migration
  000040 (`oauth_clients`). All requests go through the full `Nebu.Web.Router` (real flow, no
  handler stubs); the OAuth config is injected via the `:oauth_config_source` seam.

  Fixture rule: all clients use `client_uri` https://example.com (so the reverse-DNS native
  scheme is `com.example.*`) and a UNIQUE `client_name`, so rows never dedup across tests.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    {:ok, ids} = Agent.start(fn -> [] end)

    on_exit(fn ->
      T.cleanup_clients(Agent.get(ids, & &1))
      Agent.stop(ids)
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, track: fn id -> Agent.update(ids, &[id | &1]); id end}
  end

  # POST + assert 201 + return decoded body; tracks client_id for cleanup.
  defp register_ok(body, track, opts \\ []) do
    conn = T.register(body, opts)
    assert conn.status == 201, "expected 201, got #{conn.status}: #{conn.resp_body}"
    resp = T.json(conn)
    track.(resp["client_id"])
    {conn, resp}
  end

  # ── AC2 + AC4: web client success ──────────────────────────────────────────

  describe "AC2/AC4 — web client registers successfully (pending approval)" do
    test "201 + server-generated client_id + registered metadata; row is `pending`", %{track: track} do
      body =
        T.web_body(%{
          "logo_uri" => "https://example.com/logo.png",
          "tos_uri" => "https://example.com/tos",
          "policy_uri" => "https://example.com/privacy"
        })

      {conn, resp} = register_ok(body, track)

      assert (T.header(conn, "content-type") || "") =~ "application/json"
      assert is_binary(resp["client_id"]) and byte_size(resp["client_id"]) >= 16
      assert resp["client_name"] == body["client_name"]
      assert resp["client_uri"] == "https://example.com"
      assert resp["redirect_uris"] == ["https://example.com/callback"]
      assert resp["logo_uri"] == "https://example.com/logo.png"
      assert resp["application_type"] == "web"
      assert resp["token_endpoint_auth_method"] == "none"
      assert resp["response_types"] == ["code"]
      assert Enum.sort(resp["grant_types"]) == ["authorization_code", "refresh_token"]

      row = T.client_row(resp["client_id"])
      assert row["status"] == "pending"
      assert row["application_type"] == "web"
      assert row["token_endpoint_auth_method"] == "none"
      assert row["approved_by"] == nil and row["approved_at"] == nil
      assert row["rejected_by"] == nil and row["rejected_at"] == nil
      assert row["created_at"] != nil
      assert is_binary(row["created_from_ip"]) and row["created_from_ip"] != ""
    end

    test "the 201 is not cacheable (Cache-Control: no-store) and carries the CORS header", %{track: track} do
      {conn, _resp} = register_ok(T.web_body(), track)
      assert T.header(conn, "cache-control") == "no-store"
      assert T.header(conn, "access-control-allow-origin") == "*"
    end

    test "every new registration starts pending — there is NO auto-approval", %{track: track} do
      for _ <- 1..3 do
        {_, resp} = register_ok(T.web_body(), track)
        assert T.client_row(resp["client_id"])["status"] == "pending"
      end
    end

    test "response contains ONLY registered metadata: unknown fields are dropped, not echoed or stored",
         %{track: track} do
      body =
        T.web_body(%{
          "x_unknown_field" => "boom",
          "client_secret" => "s3cr3t-never-echo",
          "jwks_uri" => "https://example.com/jwks"
        })

      {_, resp} = register_ok(body, track)

      refute Map.has_key?(resp, "x_unknown_field")
      refute Map.has_key?(resp, "client_secret"), "a public client has no secret"
      refute resp |> Jason.encode!() |> String.contains?("s3cr3t-never-echo")

      stored = T.client_row(resp["client_id"])["metadata"]
      refute Map.has_key?(stored, "x_unknown_field")
      refute Map.has_key?(stored, "client_secret")
    end

    test "application_type omitted => web", %{track: track} do
      {_, resp} = register_ok(T.web_body() |> Map.delete("application_type"), track)
      assert resp["application_type"] == "web"
      assert T.client_row(resp["client_id"])["application_type"] == "web"
    end

    test "token_endpoint_auth_method=none is accepted and omitted => none", %{track: track} do
      {_, resp} = register_ok(T.web_body(%{"token_endpoint_auth_method" => "none"}), track)
      assert resp["token_endpoint_auth_method"] == "none"

      {_, resp2} = register_ok(T.web_body() |> Map.delete("token_endpoint_auth_method"), track)
      assert T.client_row(resp2["client_id"])["token_endpoint_auth_method"] == "none"
    end

    test "logo_uri / tos_uri / policy_uri with other port, path or query on the client host are accepted",
         %{track: track} do
      body =
        T.web_body(%{
          "logo_uri" => "https://example.com:8443/static/logo.png?v=2",
          "tos_uri" => "https://example.com/legal/tos",
          "policy_uri" => "https://example.com/legal/privacy"
        })

      {_, resp} = register_ok(body, track)
      assert resp["logo_uri"] == "https://example.com:8443/static/logo.png?v=2"
    end
  end

  # ── AC2: response_types / grant_types ──────────────────────────────────────

  describe "AC2 — response_types / grant_types" do
    test "unknown response_types are IGNORED (not rejected) and omitted from the response", %{track: track} do
      {_, resp} = register_ok(T.web_body(%{"response_types" => ["code", "token", "unknown_type"]}), track)
      assert resp["response_types"] == ["code"]
    end

    test "unknown grant_types are IGNORED and omitted from the response", %{track: track} do
      body = T.web_body(%{"grant_types" => ["authorization_code", "refresh_token", "implicit", "urn:x:custom"]})
      {_, resp} = register_ok(body, track)
      assert Enum.sort(resp["grant_types"]) == ["authorization_code", "refresh_token"]
    end

    test "missing response_types defaults to [\"code\"]", %{track: track} do
      {_, resp} = register_ok(T.web_body() |> Map.delete("response_types"), track)
      assert resp["response_types"] == ["code"]
    end

    test "missing grant_types defaults to [authorization_code, refresh_token]", %{track: track} do
      {_, resp} = register_ok(T.web_body() |> Map.delete("grant_types"), track)
      assert Enum.sort(resp["grant_types"]) == ["authorization_code", "refresh_token"]
    end

    test "grant_types explicitly [authorization_code] only is accepted and kept as supported", %{track: track} do
      {_, resp} = register_ok(T.web_body(%{"grant_types" => ["authorization_code"]}), track)
      assert "authorization_code" in resp["grant_types"]
    end
  end

  # ── AC2: native + claimed https + valid redirect URI matrix ────────────────

  describe "AC2 — native clients" do
    test "reverse-DNS private-use scheme (client_uri host mobileapp.example.io)", %{track: track} do
      body =
        T.native_body(%{
          "client_uri" => "https://mobileapp.example.io",
          "redirect_uris" => ["io.example.mobileapp:/oauth2/callback"]
        })

      {_, resp} = register_ok(body, track)
      assert resp["application_type"] == "native"
      assert T.client_row(resp["client_id"])["application_type"] == "native"
    end

    test "loopback http://localhost WITHOUT port is accepted (any port is accepted later, at authorize time)",
         %{track: track} do
      {_, resp} = register_ok(T.native_body(%{"redirect_uris" => ["http://localhost/oauth2/callback"]}), track)
      assert T.client_row(resp["client_id"])["application_type"] == "native"
    end

    test "claimed https redirect follows the web rules", %{track: track} do
      {_, resp} = register_ok(T.native_body(%{"redirect_uris" => ["https://app.example.com/cb"]}), track)
      assert resp["application_type"] == "native"
    end
  end

  @valid_redirects [
    {"web", "https://example.com/callback"},
    {"web", "https://sub.example.com/callback"},
    {"web", "https://app.example.com/cb"},
    {"web", "https://example.com:5173/?q=v"},
    {"web", "https://example.com:5173/callback"},
    {"web", "https://example.com/callback?state=123"},
    {"native", "com.example.app:/callback"},
    {"native", "com.example.app:callback"},
    {"native", "com.example:callback"},
    {"native", "com.example.app:/oauth2/callback"},
    {"native", "http://localhost/callback"},
    {"native", "http://localhost/cb"},
    {"native", "http://127.0.0.1/callback"},
    {"native", "http://[::1]/callback"},
    {"native", "http://[::1]/cb"},
    {"native", "https://app.example.com/cb"}
  ]

  describe "AC2 — valid redirect URI matrix (client_uri https://example.com)" do
    for {type, uri} <- @valid_redirects do
      test "#{type} client with redirect_uri #{uri} => 201", %{track: track} do
        body = T.web_body(%{"application_type" => unquote(type), "redirect_uris" => [unquote(uri)]})
        {_, resp} = register_ok(body, track)
        assert resp["redirect_uris"] == [unquote(uri)]
      end
    end
  end

  # ── AC2: rejected requests must not create rows ────────────────────────────

  describe "code-review 2 — data PostgreSQL refuses is a client error, never a 503" do
    test "ClientStore.register/1 maps a jsonb-unstorable value (NUL) to {:error, :invalid_metadata}" do
      name = "NulApp-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower) <> <<0>> <> "x"
      metadata = T.web_body(%{"client_name" => name})
      hash = Nebu.OAuth.Registration.hash(metadata)

      assert {:error, :invalid_metadata} =
               Nebu.OAuth.ClientStore.register(%{
                 metadata: metadata,
                 hash: hash,
                 application_type: "web",
                 token_endpoint_auth_method: "none"
               })

      assert T.count_by_hash(hash) == 0
    end

    test "the HTTP edge answers a NUL client_name with 400 invalid_client_metadata and stores nothing" do
      name = "NulHttp-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      T.register(T.web_body(%{"client_name" => name <> "\u0000"}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")

      %{rows: [[n]]} =
        T.sql!("SELECT count(*) FROM oauth_clients WHERE metadata->>'client_name' LIKE $1", [name <> "%"])

      assert n == 0
    end
  end

  describe "AC2 — rejected registrations are NOT created" do
    test "invalid_redirect_uri creates no row" do
      name = "NoRow-redirect-#{System.unique_integer([:positive])}"

      T.register(T.web_body(%{"client_name" => name, "redirect_uris" => ["http://example.com/callback"]}))
      |> T.assert_oauth_error(400, "invalid_redirect_uri")

      assert T.count_by_client_name(name) == 0
    end

    test "invalid_client_metadata creates no row" do
      name = "NoRow-meta-#{System.unique_integer([:positive])}"

      T.register(T.web_body(%{"client_name" => name, "application_type" => "custom"}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")

      assert T.count_by_client_name(name) == 0
    end

    test "explicit exclusion of code / authorization_code creates no row" do
      name = "NoRow-types-#{System.unique_integer([:positive])}"

      T.register(T.web_body(%{"client_name" => name, "response_types" => ["token"]}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")

      T.register(T.web_body(%{"client_name" => name, "grant_types" => ["implicit"]}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")

      assert T.count_by_client_name(name) == 0
    end
  end

  # ── AC3: deduplication ─────────────────────────────────────────────────────

  describe "AC3 — metadata_hash deduplication" do
    test "identical metadata => 201 with the SAME client_id and exactly ONE row", %{track: track} do
      body = T.web_body()
      {_, first} = register_ok(body, track)
      {_, second} = register_ok(body, track)

      assert first["client_id"] == second["client_id"]
      hash = T.client_row(first["client_id"])["metadata_hash"]
      assert T.count_by_hash(hash) == 1
      assert T.count_by_client_name(body["client_name"]) == 1
    end

    test "metadata_hash is a 64-char lowercase hex SHA-256 and differs for different metadata", %{track: track} do
      {_, a} = register_ok(T.web_body(), track)
      {_, b} = register_ok(T.web_body(), track)

      ha = T.client_row(a["client_id"])["metadata_hash"]
      hb = T.client_row(b["client_id"])["metadata_hash"]
      assert ha =~ ~r/^[0-9a-f]{64}$/
      assert hb =~ ~r/^[0-9a-f]{64}$/
      refute ha == hb
      refute a["client_id"] == b["client_id"]
    end

    test "dedup is independent of JSON key order (hash is order-independent)", %{track: track} do
      name = "OrderApp-#{System.unique_integer([:positive])}"

      json_a =
        ~s({"client_name":"#{name}","client_uri":"https://example.com","redirect_uris":["https://example.com/cb"],"application_type":"web"})

      json_b =
        ~s({"application_type":"web","redirect_uris":["https://example.com/cb"],"client_uri":"https://example.com","client_name":"#{name}"})

      {_, first} = register_ok(json_a, track)
      {_, second} = register_ok(json_b, track)

      assert first["client_id"] == second["client_id"]
      assert T.count_by_client_name(name) == 1
    end

    test "dedup is the same across different IPs (approval is per metadata hash, not per device)",
         %{track: track} do
      body = T.web_body()
      {_, first} = register_ok(body, track, ip: {10, 1, 1, 1})
      {_, second} = register_ok(body, track, ip: {10, 2, 2, 2})
      assert first["client_id"] == second["client_id"]
    end

    test "omitting a defaulted field and sending the default explicitly hash identically (normalized metadata)",
         %{track: track} do
      name = "DefaultsApp-#{System.unique_integer([:positive])}"
      base = T.web_body(%{"client_name" => name}) |> Map.delete("application_type")
      {_, first} = register_ok(base, track)
      {_, second} = register_ok(Map.put(base, "application_type", "web"), track)

      assert first["client_id"] == second["client_id"]
    end

    test "#lang-suffixed keys are dropped BEFORE hashing and never stored", %{track: track} do
      name = "LangApp-#{System.unique_integer([:positive])}"
      base = T.web_body(%{"client_name" => name})

      {_, plain} = register_ok(base, track)
      {_, with_de} = register_ok(Map.put(base, "client_name#de", "Meine App"), track)
      {_, with_fr} = register_ok(Map.merge(base, %{"client_name#fr" => "Mon App", "tos_uri#de" => "https://example.com/de"}), track)

      assert plain["client_id"] == with_de["client_id"]
      assert plain["client_id"] == with_fr["client_id"]

      stored = T.client_row(plain["client_id"])["metadata"]
      assert stored["client_name"] == name
      refute Enum.any?(Map.keys(stored), &String.contains?(&1, "#")), "stored keys: #{inspect(Map.keys(stored))}"
      assert T.count_by_client_name(name) == 1
    end

    test "system/audit fields in the request (client_id, created_at, approved_by, …) do not affect the hash",
         %{track: track} do
      name = "SysFieldApp-#{System.unique_integer([:positive])}"
      base = T.web_body(%{"client_name" => name})
      noisy = Map.merge(base, %{"client_id" => "forged-id", "created_at" => "2020-01-01", "approved_by" => "@evil:x"})

      {_, first} = register_ok(base, track)
      {_, second} = register_ok(noisy, track)

      assert first["client_id"] == second["client_id"]
      refute first["client_id"] == "forged-id"
      assert T.client_row(first["client_id"])["approved_by"] == nil
    end

    test "re-registering a REJECTED client returns the SAME client_id and keeps it rejected", %{track: track} do
      body = T.web_body()
      {_, first} = register_ok(body, track)

      T.sql!(
        "UPDATE oauth_clients SET status = 'rejected', rejected_by = '@admin:test.local', rejected_at = NOW(), source_key = NULL WHERE client_id = $1",
        [first["client_id"]]
      )

      {_, second} = register_ok(body, track)
      assert second["client_id"] == first["client_id"]

      row = T.client_row(first["client_id"])
      assert row["status"] == "rejected", "re-registration must NOT reset a rejected client to pending"
      assert row["rejected_by"] == "@admin:test.local"
    end

    test "re-registering an APPROVED client returns the same client_id and keeps it approved", %{track: track} do
      body = T.web_body()
      {_, first} = register_ok(body, track)

      T.sql!(
        "UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = NOW(), source_key = NULL WHERE client_id = $1",
        [first["client_id"]]
      )

      {_, second} = register_ok(body, track)
      assert second["client_id"] == first["client_id"]
      assert T.client_row(first["client_id"])["status"] == "approved"
    end
  end

  # ── AC3/Cluster safety: concurrency ────────────────────────────────────────

  describe "AC3/ADR-020 — concurrent identical registrations are idempotent" do
    for n <- [2, 3, 10] do
      test "#{n} simultaneous identical POSTs => all 201, SAME client_id, ONE row", %{track: track} do
        body = T.web_body()
        name = body["client_name"]

        responses =
          1..unquote(n)
          |> Task.async_stream(fn i -> T.register(body, ip: {10, 50, unquote(n), i}) end,
            max_concurrency: unquote(n),
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, conn} -> conn end)

        assert Enum.all?(responses, &(&1.status == 201)),
               "statuses: #{inspect(Enum.map(responses, & &1.status))}"

        ids = responses |> Enum.map(&(T.json(&1)["client_id"])) |> Enum.uniq()
        Enum.each(ids, track)
        assert length(ids) == 1, "concurrent identical registrations returned different client_ids: #{inspect(ids)}"
        assert T.count_by_client_name(name) == 1
      end
    end
  end

  # ── AC7: logging ───────────────────────────────────────────────────────────

  describe "AC7 — logging" do
    setup do
      original = Logger.level()
      on_exit(fn -> Logger.configure(level: original) end)
      :ok
    end

    test "INFO: logs carry client_id and metadata_hash but NEVER the full metadata", %{track: track} do
      Logger.configure(level: :info)
      n = System.unique_integer([:positive])
      name = "LogSentinelName#{n}"
      body = T.web_body(%{"client_name" => name, "redirect_uris" => ["https://example.com/sentinelpath#{n}"]})

      log =
        capture_log([level: :info], fn ->
          {_, resp} = register_ok(body, track)
          send(self(), {:client_id, resp["client_id"]})
        end)

      assert_received {:client_id, client_id}
      hash = T.client_row(client_id)["metadata_hash"]

      assert log =~ client_id, "INFO log must contain the client_id (audit)"
      assert log =~ hash, "INFO log must contain the metadata_hash (audit)"
      refute log =~ name, "INFO log must NOT contain client metadata (client_name)"
      refute log =~ "sentinelpath#{n}", "INFO log must NOT contain client metadata (redirect_uris)"
    end

    test "DEBUG: payload logging applies the redactor — a submitted client_secret never appears", %{track: track} do
      Logger.configure(level: :debug)
      secret = "DbgSecret-#{System.unique_integer([:positive])}"
      body = T.web_body(%{"client_secret" => secret})

      log =
        capture_log([level: :debug], fn ->
          register_ok(body, track)
        end)

      # Positive assertions first: without them the refute below would pass vacuously when
      # nothing is logged at DEBUG at all (or when the request payload is never captured).
      assert log =~ "client_secret", "DEBUG payload line for POST /oauth2/register missing (vacuous test guard)"
      assert log =~ body["client_name"], "DEBUG payload must still carry public client metadata (client_name)"
      assert log =~ "***REDACTED***", "the submitted client_secret must be replaced by the redaction marker"

      refute log =~ secret, "DEBUG log leaked a plaintext client_secret"
    end
  end
end
