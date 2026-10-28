defmodule Nebu.OAuth.OAuthSigningKeysTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint`, AC13 / T17 / T18 / Must #27:
  Nebu's ES256 id_token signing keys (`Nebu.OAuth.SigningKeyStore`, table `oauth_signing_keys`,
  migration 000042) and `GET /oauth2/jwks`.

  * lazy, cluster-safe generation: `ensure_active_key/0` on an empty table creates exactly ONE
    active row, also under N concurrent callers (`INSERT ... ON CONFLICT DO NOTHING` + re-SELECT;
    no node-local "which kid is active" state)
  * private key only as SecretBox ciphertext; the decrypted key's thumbprint = `kid`, its public
    part = `public_jwk` (a swapped ciphertext fails closed with `:key_inconsistent`)
  * JWKS shape/headers, retired keys published until `not_after`, kill switch, rate limit
  * runtime role (`nebu_app`) behaviour: no DELETE, key material immutable, no re-activation

  Red today: no `Nebu.OAuth.SigningKeyStore` module, no `oauth_signing_keys` table, no
  `/oauth2/jwks` route (router plain 404).

  Trap 8: no failure message ever inspects a `%JOSE.JWK{}`, a key row or the private map; only kids
  and booleans are printed.

  The table is emptied with the PRIVILEGED role before and after every test (the runtime role has
  no DELETE). Other test files create the active key lazily on demand, so emptying it is harmless.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @store Nebu.OAuth.SigningKeyStore
  @jwk_members ~w(alg crv kid kty use x y)

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.reset_signing_keys!()

    on_exit(fn ->
      T.reset_signing_keys!()
      T.clear_oauth_config()
      T.restore_rate_limits()
      Application.delete_env(:nebu_http, :oauth_repo)
      Application.delete_env(:nebu_http, :oauth_session_repo)
    end)

    {:ok, priv: priv}
  end

  # ── helpers (never print key material) ─────────────────────────────────────

  defp ensure, do: apply(@store, :ensure_active_key, [])

  defp ensure! do
    case ensure() do
      {:ok, %{kid: kid, jwk: %JOSE.JWK{} = jwk}} when is_binary(kid) -> {kid, jwk}
      {:ok, _} -> flunk("ensure_active_key/0 must return {:ok, %{kid: binary, jwk: %JOSE.JWK{}}}")
      {:error, reason} -> flunk("ensure_active_key/0 failed: #{inspect(reason)}")
      _ -> flunk("ensure_active_key/0 returned an unexpected shape")
    end
  end

  # Asserts an `{:error, _}` result WITHOUT inspecting a success value (it would carry the key).
  defp assert_error!({:error, _}), do: :ok
  defp assert_error!({:ok, _}), do: flunk("expected {:error, _}, got {:ok, <key>} (fail closed required)")
  defp assert_error!(_), do: flunk("expected {:error, _}, got an unexpected shape")

  defp kids(rows), do: Enum.map(rows, & &1["kid"])

  # A fresh P-256 key as stored by the implementation would store it.
  defp new_key do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pub} = JOSE.JWK.to_public_map(jwk)
    {_, priv} = JOSE.JWK.to_map(jwk)
    %{jwk: jwk, kid: JOSE.JWK.thumbprint(jwk), pub: pub, priv_json: Jason.encode!(priv)}
  end

  defp privileged_insert!(kid, pub, enc, status, extra_sql \\ "") do
    {cols, vals} =
      case status do
        "active" -> {"", ""}
        "retired" -> {", retired_at, not_after, created_at", extra_sql}
      end

    T.privileged_sql!(
      "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status#{cols}) " <>
        "VALUES ($1, 'ES256', $2::text::jsonb, $3, $4#{vals})",
      [kid, Jason.encode!(pub), enc, status]
    )
  end

  defp insert_retired!(not_after_sql, created_sql) do
    k = new_key()
    privileged_insert!(k.kid, k.pub, Nebu.Web.SecretBox.encrypt(k.priv_json), "retired", ", now(), #{not_after_sql}, #{created_sql}")
    k.kid
  end

  defp published_kids do
    case apply(@store, :published_keys, []) do
      {:ok, keys} when is_list(keys) ->
        for k <- keys do
          refute Map.has_key?(k, "d"), "published_keys/0 must return PUBLIC maps only"
          k["kid"]
        end

      other ->
        flunk("published_keys/0 must return {:ok, list}, got #{if match?({:error, _}, other), do: inspect(other), else: "an unexpected shape"}")
    end
  end

  defp column_values(row), do: Enum.map(row, fn {_k, v} -> if is_map(v), do: Jason.encode!(v), else: to_string(v) end)

  # ════════════════════════════════════════════════════════════════════════════
  # lazy generation (T18)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC13/T18 — ensure_active_key/0: lazy, single active key" do
    test "an empty table => one active ES256 row; kid = RFC 7638 thumbprint; public_jwk without d" do
      {kid, jwk} = ensure!()
      assert kid == JOSE.JWK.thumbprint(jwk), "kid must be the RFC 7638 thumbprint of the key"

      assert [row] = T.signing_key_rows()
      assert row["kid"] == kid
      assert row["alg"] == "ES256"
      assert row["status"] == "active"
      assert row["retired_at"] == nil
      assert row["not_after"] == nil
      assert is_map(row["public_jwk"])
      refute Map.has_key?(row["public_jwk"], "d"), "public_jwk must never carry the private member d"
      assert row["public_jwk"]["kty"] == "EC" and row["public_jwk"]["crv"] == "P-256"
    end

    test "the private JWK is stored only as SecretBox ciphertext: it decrypts to the same key; no plaintext d anywhere" do
      {kid, _jwk} = ensure!()
      [row] = T.signing_key_rows()
      enc = row["private_jwk_enc"]
      assert is_binary(enc) and enc =~ ~r/\A[0-9a-f]+\z/, "private_jwk_enc must be the hex SecretBox blob"

      plain =
        case Nebu.Web.SecretBox.decrypt(enc) do
          {:ok, p} -> p
          _ -> flunk("private_jwk_enc does not decrypt with the SecretBox key")
        end

      priv = Jason.decode!(plain)
      d = priv["d"]
      assert is_binary(d) and byte_size(d) > 20, "the decrypted private JWK carries d"
      assert JOSE.JWK.thumbprint(JOSE.JWK.from_map(priv)) == kid, "the ciphertext belongs to this kid"

      leaked? = Enum.any?(column_values(row), &String.contains?(&1, d))
      refute leaked?, "the private member d appears in plaintext in a column"
      refute String.contains?(enc, plain), "ciphertext must not contain the plaintext JSON"
    end

    test "a second call returns the SAME kid and creates no row" do
      {kid1, _} = ensure!()
      {kid2, _} = ensure!()
      assert kid1 == kid2
      assert length(T.signing_key_rows()) == 1
    end

    test "N = 12 concurrent callers on an empty table: exactly ONE row, the same kid everywhere (cluster-safe)" do
      # test review (b): 5 rounds, every round on an EMPTY table, all callers released at once by a
      # barrier (each task blocks until :go), so a check-then-insert implementation without
      # `INSERT ... ON CONFLICT DO NOTHING` + re-SELECT loses reliably.
      for round <- 1..5 do
        if round > 1, do: T.reset_signing_keys!()

        tasks =
          for _ <- 1..12 do
            Task.async(fn ->
              receive do
                :go -> apply(@store, :ensure_active_key, [])
              end
            end)
          end

        Enum.each(tasks, &send(&1.pid, :go))
        results = Task.await_many(tasks, 30_000)

        kids =
          for r <- results do
            case r do
              {:ok, %{kid: kid}} when is_binary(kid) -> kid
              {:error, reason} -> flunk("round #{round}: a concurrent caller failed: #{inspect(reason)}")
              _ -> flunk("round #{round}: a concurrent caller returned an unexpected shape")
            end
          end

        assert length(Enum.uniq(kids)) == 1,
               "round #{round}: all callers must see the single winner's kid, got #{length(Enum.uniq(kids))} kids"

        rows = T.signing_key_rows()
        assert length(rows) == 1, "round #{round}: exactly one row expected, got #{length(rows)}"
        assert kids(rows) == [hd(kids)]
      end
    end

    test "published_keys/0: active first, then retired with not_after > now (newest first); expired retired keys are not published" do
      {active, _} = ensure!()
      older = insert_retired!("now() + interval '1 day'", "now() - interval '3 days'")
      newer = insert_retired!("now() + interval '1 day'", "now() - interval '2 days'")
      _expired = insert_retired!("now() - interval '1 hour'", "now() - interval '4 days'")

      assert published_kids() == [active, newer, older]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # consistency check (T18: SecretBox has no associated data)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC13/T18 — the loaded key is verified against kid and public_jwk (fail closed)" do
    test "an active row whose ciphertext encrypts ANOTHER key => {:error, :key_inconsistent}; JWKS 503 {}" do
      a = new_key()
      b = new_key()
      privileged_insert!(a.kid, a.pub, Nebu.Web.SecretBox.encrypt(b.priv_json), "active")

      case apply(@store, :ensure_active_key, []) do
        {:error, :key_inconsistent} -> :ok
        {:ok, _} -> flunk("a swapped ciphertext must never yield a signing key")
        other -> flunk("expected {:error, :key_inconsistent}, got #{if match?({:error, _}, other), do: inspect(other), else: "an unexpected shape"}")
      end

      T.jwks() |> T.assert_5xx_empty(503)
      assert kids(T.signing_key_rows()) == [a.kid], "no second key is generated next to the inconsistent one"
    end

    test "kid = thumbprint of the DECRYPTED key but the stored public_jwk differs => {:error, :key_inconsistent} (T18 second check)" do
      a = new_key()
      b = new_key()
      # ciphertext and kid belong to A, but the published public part is B's: signing with A would
      # produce id_tokens nobody can verify against the JWKS => fail closed.
      privileged_insert!(a.kid, b.pub, Nebu.Web.SecretBox.encrypt(a.priv_json), "active")

      case apply(@store, :ensure_active_key, []) do
        {:error, :key_inconsistent} -> :ok
        {:ok, _} -> flunk("a public_jwk that does not match the private key must never yield a signing key")
        other -> flunk("expected {:error, :key_inconsistent}, got #{if match?({:error, _}, other), do: inspect(other), else: "an unexpected shape"}")
      end

      T.jwks() |> T.assert_5xx_empty(503)
    end

    test "a tampered (garbage hex) ciphertext => {:error, _}, never a key" do
      a = new_key()
      privileged_insert!(a.kid, a.pub, String.duplicate("ab", 64), "active")
      assert_error!(apply(@store, :ensure_active_key, []))
      T.jwks() |> T.assert_5xx_empty(503)
    end

    test "SecretBox unavailable (no internal secret) on an empty table => {:error, _} (rescued) and JWKS 503 {}" do
      secret = Application.get_env(:nebu_http, :admin_secret_at_rest)
      Application.delete_env(:nebu_http, :admin_secret_at_rest)

      try do
        result =
          try do
            apply(@store, :ensure_active_key, [])
          rescue
            e -> flunk("ensure_active_key/0 must rescue a SecretBox failure, raised #{inspect(e.__struct__)}")
          end

        assert_error!(result)
        T.jwks() |> T.assert_5xx_empty(503)
        assert T.signing_key_rows() == [], "no key row without encryption"
      after
        Application.put_env(:nebu_http, :admin_secret_at_rest, secret)
      end
    end

    test "repository unavailable (:oauth_repo NoSuchRepo) => {:error, _} and JWKS 503 {}" do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      assert_error!(apply(@store, :ensure_active_key, []))
      assert_error!(apply(@store, :published_keys, []))
      T.jwks() |> T.assert_5xx_empty(503)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # GET /oauth2/jwks
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC13 — GET /oauth2/jwks" do
    test "an empty table: the key is generated lazily, the set is never empty; exact public members" do
      conn = T.jwks()
      assert conn.status == 200, "got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
      assert [key] = T.json(conn)["keys"]
      assert key |> Map.keys() |> Enum.sort() == @jwk_members, "exact members #{inspect(@jwk_members)}"
      assert key["kty"] == "EC" and key["crv"] == "P-256" and key["use"] == "sig" and key["alg"] == "ES256"
      assert key["kid"] == hd(kids(T.signing_key_rows()))
      refute conn.resp_body =~ ~s("d"), "no private member in the JWKS"
    end

    test "headers: JSON, Cache-Control public, max-age=600, ACAO *, no Allow-Credentials" do
      conn = T.jwks(origin: "https://client.example.com")
      assert conn.status == 200
      assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}
      assert T.header(conn, "cache-control") == "public, max-age=600"
      assert T.header(conn, "access-control-allow-origin") == "*"
      assert T.header(conn, "access-control-allow-credentials") == nil
    end

    test "the published public key verifies a signature made with the stored private key" do
      {kid, jwk} = ensure!()
      [key] = T.jwks_keys!()
      assert key["kid"] == kid

      {_, token} =
        JOSE.JWT.sign(jwk, %{"alg" => "ES256", "kid" => kid, "typ" => "JWT"}, %{"sub" => "x"})
        |> JOSE.JWS.compact()

      assert {true, _, _} = JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["ES256"], token)
    end

    test "active + retired (not_after > now) are published; an expired retired key is not" do
      {active, _} = ensure!()
      retired = insert_retired!("now() + interval '1 day'", "now() - interval '2 days'")
      expired = insert_retired!("now() - interval '1 minute'", "now() - interval '3 days'")

      published = Enum.map(T.jwks_keys!(), & &1["kid"])
      assert published == [active, retired]
      refute expired in published
    end

    test "sub-path => 404 M_UNRECOGNIZED; non-GET => 405 invalid_request + Allow: GET, OPTIONS" do
      T.get("/oauth2/jwks/x") |> T.assert_unrecognized_404_no_error()

      for method <- [:post, :put, :delete] do
        conn = Plug.Test.conn(method, "/oauth2/jwks", "") |> Map.put(:remote_ip, T.unique_ip()) |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
        assert conn.status == 405, "#{method} => #{conn.status}"
        assert T.json(conn)["error"] == "invalid_request"
        assert T.header(conn, "allow") == "GET, OPTIONS"
      end
    end

    test "OPTIONS preflight: CORS headers (Allow-Headers incl. Content-Type, Authorization), no DB, no key generation" do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      conn = T.options("/oauth2/jwks", request_method: "GET")
      assert conn.status in [200, 204]
      assert T.header(conn, "access-control-allow-origin") == "*"
      allow_headers = String.downcase(T.header(conn, "access-control-allow-headers") || "")
      assert allow_headers =~ "content-type" and allow_headers =~ "authorization"
      Application.delete_env(:nebu_http, :oauth_repo)
      assert T.signing_key_rows() == [], "a preflight never generates a key"
    end

    test "rate limit {\"oauth_jwks\", ip}: an exhausted bucket => 429 too_many_requests + Retry-After" do
      ip = T.unique_ip()
      T.drain!("oauth_jwks", ip, 10, 600)
      conn = T.jwks(ip: ip)
      assert conn.status == 429
      assert T.json(conn)["error"] == "too_many_requests"
      refute Map.has_key?(T.json(conn), "errcode")
      assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert secs > 0
      refute T.jwks(ip: T.unique_ip()).status == 429, "other IPs are unaffected"
    end

    test "kill switch: disabled / invalid issuer => 404 M_UNRECOGNIZED without DB; :unknown => 503 {} + Retry-After" do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      T.disable_oauth()
      T.jwks() |> T.assert_unrecognized_404_no_error()
      T.enable_oauth("http://nebu.example.com")
      T.jwks() |> T.assert_unrecognized_404_no_error()
      T.unreadable_oauth_config()
      T.jwks() |> T.assert_5xx_empty(503)
      Application.delete_env(:nebu_http, :oauth_repo)
      assert T.signing_key_rows() == []
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # logging (AC19, Must #31)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC19 — key generation and JWKS never log key material" do
    test "DEBUG log over lazy generation + JWKS: no d, no ciphertext" do
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      log =
        capture_log([level: :debug], fn ->
          assert T.jwks().status == 200
          _ = apply(@store, :ensure_active_key, [])
        end)

      [row] = T.signing_key_rows()
      {:ok, plain} = Nebu.Web.SecretBox.decrypt(row["private_jwk_enc"])
      d = Jason.decode!(plain)["d"]
      refute String.contains?(log, d), "the private member d leaked into the log"
      refute String.contains?(log, row["private_jwk_enc"]), "the SecretBox ciphertext leaked into the log"
      refute String.contains?(log, String.slice(row["private_jwk_enc"], 0, 32))
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # runtime role (000042 RLS + guard trigger, Must #27/#32)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14 — the runtime role (nebu_app) and oauth_signing_keys" do
    test "cannot DELETE a key (no grant / no policy)" do
      {kid, _} = ensure!()

      result =
        try do
          T.sql!("DELETE FROM oauth_signing_keys WHERE kid = $1", [kid])
        rescue
          e in Postgrex.Error -> {:raised, Exception.message(e)}
        end

      case result do
        {:raised, msg} -> assert msg =~ ~r/permission denied|policy/i
        %{num_rows: n} -> assert n == 0
      end

      assert kids(T.signing_key_rows()) == [kid]
    end

    test "cannot change key material (kid, alg, public_jwk, private_jwk_enc, created_at)" do
      {kid, _} = ensure!()

      for set <- ["kid = 'other'", "alg = 'ES256K'", "public_jwk = '{}'::jsonb", "private_jwk_enc = 'abcd'",
                  "created_at = now() - interval '1 day'"] do
        assert_raise Postgrex.Error, fn -> T.sql!("UPDATE oauth_signing_keys SET #{set} WHERE kid = $1", [kid]) end
      end

      assert [row] = T.signing_key_rows()
      assert row["kid"] == kid and row["alg"] == "ES256"
    end

    test "can retire (active -> retired with retired_at, not_after set/raised); cannot re-activate; cannot retire without retired_at; cannot lower not_after" do
      {kid, _} = ensure!()

      assert_raise Postgrex.Error, fn ->
        T.sql!("UPDATE oauth_signing_keys SET status = 'retired' WHERE kid = $1", [kid])
      end

      assert %{num_rows: 1} =
               T.sql!(
                 "UPDATE oauth_signing_keys SET status = 'retired', retired_at = now(), not_after = now() + interval '1 day' WHERE kid = $1",
                 [kid]
               )

      assert %{num_rows: 1} = T.sql!("UPDATE oauth_signing_keys SET not_after = now() + interval '2 days' WHERE kid = $1", [kid])

      assert_raise Postgrex.Error, fn ->
        T.sql!("UPDATE oauth_signing_keys SET not_after = now() + interval '1 hour' WHERE kid = $1", [kid])
      end

      assert_raise Postgrex.Error, fn ->
        T.sql!("UPDATE oauth_signing_keys SET status = 'active', retired_at = NULL WHERE kid = $1", [kid])
      end

      assert [%{"status" => "retired"}] = Enum.map(T.signing_key_rows(), &Map.take(&1, ["status"]))
    end

    test "cannot insert a second active key (partial unique index) nor a retired one (RLS WITH CHECK)" do
      {_kid, _} = ensure!()
      b = new_key()

      assert_raise Postgrex.Error, ~r/unique|duplicate/i, fn ->
        T.sql!(
          "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc) VALUES ($1, 'ES256', $2::text::jsonb, $3)",
          [b.kid, Jason.encode!(b.pub), Nebu.Web.SecretBox.encrypt(b.priv_json)]
        )
      end

      c = new_key()

      assert_raise Postgrex.Error, ~r/row-level security|policy/i, fn ->
        T.sql!(
          "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status, retired_at) " <>
            "VALUES ($1, 'ES256', $2::text::jsonb, $3, 'retired', now())",
          [c.kid, Jason.encode!(c.pub), Nebu.Web.SecretBox.encrypt(c.priv_json)]
        )
      end

      assert length(T.signing_key_rows()) == 1
    end

    test "alg is fixed to ES256 by a CHECK" do
      k = new_key()

      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        T.privileged_sql!(
          "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc) VALUES ($1, 'none', $2::text::jsonb, 'x')",
          [k.kid, Jason.encode!(k.pub)]
        )
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # matrix_compat fixture (oracle C6, consumed by tests/matrix_compat/oauth_metadata_test.js)
  # ════════════════════════════════════════════════════════════════════════════

  describe "C6 — fixture for the matrix-js-sdk validateAuthMetadataAndKeys node test" do
    test "auth_metadata + JWKS + openid-configuration + REAL token-endpoint responses (written when NEBU_OAUTH_FIXTURE_OUT is set)", %{priv: priv} do
      meta = T.get_metadata()
      jwks = T.jwks()
      oidc = T.get("/.well-known/openid-configuration")

      for {name, conn} <- [auth_metadata: meta, jwks: jwks, openid_configuration: oidc] do
        assert conn.status == 200, "#{name} must answer 200, got #{conn.status}"
      end

      # test review (h): the node test replays Nebu's REAL refresh answers (200, 503 {}, 400
      # invalid_grant) through OidcTokenRefresher instead of hand-written bodies.
      cid = T.oauth_client!(["https://app.example.com/cb"])
      s = T.session!(cid, "https://app.example.com/cb", priv, authorize: %{"scope" => T.js_sdk_scope(), "nonce" => "fx-" <> T.rand()})
      T.idp_refresh_ok(s.sub)
      ok = T.refresh(cid, s.rt)
      assert ok.status == 200
      invalid = T.refresh(cid, String.duplicate("0", 64))
      assert invalid.status == 400
      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
      unavailable = T.refresh(cid, T.json(ok)["refresh_token"])
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert unavailable.status == 503

      capture = fn conn -> %{"status" => conn.status, "body" => T.json(conn), "retry_after" => T.header(conn, "retry-after")} end

      # story 9 (oauth-versions-switch, AC6 / V11): the REAL /versions bodies with OAuth offered
      # (the test's enable_oauth seam) and not offered, for the getAuthMetadata() prefix replay.
      versions_on = T.json(T.get("/_matrix/client/versions"))
      T.disable_oauth()
      versions_off = T.json(T.get("/_matrix/client/versions"))
      T.enable_oauth()

      fixture = %{
        "auth_metadata" => T.json(meta),
        "jwks" => T.json(jwks),
        "openid_configuration" => T.json(oidc),
        "token_responses" => %{"ok" => capture.(ok), "invalid_grant" => capture.(invalid), "unavailable" => capture.(unavailable)},
        "versions_on" => versions_on,
        "versions_off" => versions_off
      }

      assert fixture["auth_metadata"]["jwks_uri"] == T.issuer() <> "/oauth2/jwks"
      assert fixture["openid_configuration"] == fixture["auth_metadata"]
      assert [%{"kty" => "EC", "alg" => "ES256"} | _] = fixture["jwks"]["keys"]
      assert fixture["token_responses"]["unavailable"]["body"] == %{}

      case System.get_env("NEBU_OAUTH_FIXTURE_OUT") do
        nil -> :ok
        "" -> :ok
        path -> File.write!(path, Jason.encode!(fixture, pretty: true))
      end

      # story 9: asserted AFTER the fixture is written, so the node replay still gets its fixture when this fails.
      assert is_binary(fixture["auth_metadata"]["account_management_uri"]), "the live document carries the story-6 fields"
      assert "v1.15" in versions_on["versions"], "OAuth offered => /versions lists v1.15 (story 9 V1)"
      refute "v1.15" in versions_off["versions"]
    end
  end
end
