defmodule Nebu.Web.MediaTestSupport do
  @moduledoc """
  Shared RED-phase test support for the `media-gateway-migration` story.

  These helpers exist so the media ExUnit tests can drive the full
  `Nebu.Web.Router` Plug pipeline WITHOUT a live PostgreSQL, MinIO/S3, or
  network — by injecting fake boundaries through application env. The dev
  agent implements the real boundaries (ExAws.S3 storage, local OTP
  membership, inline-SQL `media_files` lookup, Finch fetch) and reads the
  SAME `Application.get_env(:nebu_http, ...)` keys so production code falls
  back to the real implementations when no override is set.

  ## Injected boundaries (test seams the dev MUST honor)

    * `:media_storage_module`     — `get(key) :: {:ok, binary} | {:error, term}`,
                                     `put(key, binary) :: :ok | {:error, term}`.
                                     Production: ExAws.S3 Storer.
    * `:media_membership_module`  — `member?(room_id, user_id) :: boolean`.
                                     Production: a LOCAL OTP/DB call replacing the
                                     former gRPC CheckMembership (AC2/AC4).
    * `:media_db_module`          — `lookup(server_name, media_id) ::
                                     {:ok, row_map} | {:error, :not_found}` where
                                     row_map mirrors the `media_files` columns.
                                     Production: inline SQL via
                                     Ecto.Adapters.SQL.query (ADR-018).
    * `:media_http_fetch_module`  — `fetch(url) :: {:ok, %{status, headers, body}}
                                     | {:error, term}` for preview_url.
                                     Production: Finch. SSRF guard runs BEFORE this.

  The `media_files` row shape mirrors the migration columns:
    media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
    uploader_user_id, uploaded_at, deleted, plus a Nebu-specific `room_id`
    used for the room-membership access check (the dev wires whichever column
    actually scopes media to a room — tests assert behavior, not the column).
  """

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "media-test-key-1"

  def server_name, do: @server_name
  def issuer, do: @issuer
  def audience, do: @audience
  def kid, do: @kid

  @doc "Router opts, computed once per call site."
  def router_opts, do: Nebu.Web.Router.init([])

  @doc """
  Generate an in-test RSA keypair, inject the public JWK so OidcPlug verifies
  without a network call, and return the private JWK map for signing.
  Mirrors matrix_router_test/oidc_plug_test setup.
  """
  def setup_oidc_keys do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.put("kid", @kid)
      |> Map.put("alg", "RS256")
      |> Map.put("use", "sig")

    priv_jwk = Map.put(priv_map, "kid", @kid)

    Application.put_env(:nebu_http, :server_name, @server_name)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    # oidc-bootstrap-only-config (ADR-022): issuer/audience resolve from server_config
    # (OidcConfig DB seam in tests), not from env. OidcPlug reads them via OidcConfig.get/0.
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Application.delete_env(:nebu_http, :oidc_jwks)
      Nebu.Web.OidcTestSupport.clear()
    end)

    priv_jwk
  end

  @doc """
  Sign an RS256 JWT whose `sub` becomes the Matrix user id `@<sub>:<server>`.
  Returns `{matrix_user_id, compact_token}`.
  """
  def bearer_for(sub, priv_jwk) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => System.system_time(:second) + 3600,
      "iat" => System.system_time(:second)
    }

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    {"@" <> sub <> ":" <> @server_name, compact}
  end

  @doc "Authorization header list for a bearer token."
  def auth(token), do: [{"authorization", "Bearer " <> token}]

  @doc "Decode a JSON response body."
  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "First value of a response header, as a string (\"\" if absent)."
  def header(conn, name) do
    conn |> Plug.Conn.get_resp_header(name) |> List.first() |> to_string()
  end

  @doc """
  Encrypt `plaintext` with AES-256-GCM exactly like the Go media gateway
  (`gcm.Seal` → ciphertext || 16-byte tag). Returns `{ciphertext_with_tag,
  key_hex, nonce_hex}` so a fake storage boundary can serve the ciphertext and
  the injected `media_files` row can carry the matching key/nonce hex.

  This lets the download tests assert that the migrated handler decrypts the
  encrypted-at-rest blob (ADR-011) and serves the original plaintext bytes.
  """
  def encrypt_like_go(plaintext) do
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, <<>>, true)

    {ciphertext <> tag, Base.encode16(key, case: :lower), Base.encode16(nonce, case: :lower)}
  end

  @doc """
  Build a `media_files`-shaped row map for an injected `:media_db_module`.
  `room_id` is the Nebu room scope used by the membership access check.
  """
  def media_row(opts) do
    %{
      media_id: Keyword.fetch!(opts, :media_id),
      server_name: Keyword.get(opts, :server_name, @server_name),
      content_type: Keyword.get(opts, :content_type, "image/jpeg"),
      file_size: Keyword.get(opts, :file_size, 0),
      aes_key_hex: Keyword.fetch!(opts, :aes_key_hex),
      nonce_hex: Keyword.fetch!(opts, :nonce_hex),
      uploader_user_id: Keyword.get(opts, :uploader_user_id, "@uploader:test.local"),
      uploaded_at: Keyword.get(opts, :uploaded_at, 0),
      deleted: Keyword.get(opts, :deleted, false),
      room_id: Keyword.get(opts, :room_id, "!room:test.local"),
      storage_key: Keyword.get(opts, :storage_key, Keyword.fetch!(opts, :media_id))
    }
  end
end
