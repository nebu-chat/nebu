defmodule Nebu.Web.SecretBox do
  @moduledoc """
  Small shared AES-256-GCM helper for at-rest secrets (oidc-session-refresh).

  Factors the encrypt/decrypt pattern previously inlined in
  `Nebu.Admin.BootstrapLive` (`encrypt_secret/1` / `decrypt_secret/1`) so the
  Matrix session store (encrypted OIDC refresh token) and the admin OIDC client
  secret use ONE crypto path instead of duplicating it.

  Blob layout (Go `crypto.go` parity): `hex(nonce ‖ ciphertext ‖ tag)`, where the
  12-byte random nonce is prepended and `Nebu.Media.Crypto` produces
  `ciphertext ‖ 16-byte tag`. The AES-256 key is `SHA-256(internal_secret)` — the
  same key derivation `Nebu.Admin.BootstrapLive.at_rest_key/0` uses.

  ## Fail-closed key derivation

  The key is NEVER derived from an empty secret: `SHA-256("")` is publicly
  computable, so encrypting under it gives no confidentiality. If no internal
  secret is configured `encrypt/1` and `decrypt/1` raise (mirrors the admin
  helper) — a missing secret must fail closed, not silently store plaintext-grade
  ciphertext.

  Token values themselves are never logged by callers; this module never logs.
  """

  @doc """
  Encrypts `plaintext` with AES-256-GCM under `SHA-256(internal_secret)`.
  Returns `hex(nonce ‖ ciphertext ‖ tag)`. Raises if no internal secret is set.
  """
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    key = at_rest_key()
    nonce = :crypto.strong_rand_bytes(12)
    blob = Nebu.Media.Crypto.encrypt(plaintext, key, nonce)
    Base.encode16(nonce <> blob, case: :lower)
  end

  @doc """
  Decrypts a `hex(nonce ‖ ciphertext ‖ tag)` blob produced by `encrypt/1`.
  Returns `{:ok, plaintext}` or `{:error, :decrypt_failed}` on any decode / auth-tag
  failure. Raises if no internal secret is set.
  """
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :decrypt_failed}
  def decrypt(hex_blob) when is_binary(hex_blob) do
    with {:ok, raw} <- Base.decode16(hex_blob, case: :mixed),
         <<nonce::binary-size(12), blob::binary>> <- raw,
         {:ok, plaintext} <- Nebu.Media.Crypto.decrypt(blob, at_rest_key(), nonce) do
      {:ok, plaintext}
    else
      _ -> {:error, :decrypt_failed}
    end
  end

  def decrypt(_), do: {:error, :decrypt_failed}

  # SHA-256 of the shared internal secret → 32-byte AES-256 key (Go: sha256.Sum256).
  # Reads the SAME sources as Nebu.Admin.BootstrapLive.at_rest_key/0. Fails closed
  # when no real secret is present (refuses to encrypt under SHA-256("")).
  defp at_rest_key do
    secret =
      case Application.get_env(:nebu_http, :admin_secret_at_rest) do
        s when is_binary(s) and s != "" ->
          s

        _ ->
          case System.get_env("NEBU_INTERNAL_SECRET_FILE") do
            nil -> System.get_env("NEBU_INTERNAL_SECRET", "")
            path -> path |> File.read!() |> String.trim()
          end
      end

    if secret == "" do
      raise "SecretBox key unavailable: set NEBU_INTERNAL_SECRET_FILE or " <>
              "NEBU_INTERNAL_SECRET (refusing to encrypt under SHA-256(\"\"))"
    end

    :crypto.hash(:sha256, secret)
  end
end
