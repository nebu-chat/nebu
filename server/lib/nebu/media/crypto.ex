defmodule Nebu.Media.Crypto do
  @moduledoc """
  AES-256-GCM encrypt/decrypt with byte-for-byte parity to the Go media gateway
  (`media/internal/crypto/aes.go`).

  Go's `gcm.Seal(nil, nonce, plaintext, nil)` returns `ciphertext || 16-byte tag`.
  Erlang's `:crypto.crypto_one_time_aead/6` returns `{ciphertext, tag}` separately,
  so we concatenate `ciphertext <> tag` on encrypt and split the trailing 16 bytes
  as the tag on decrypt. This matches `MediaTestSupport.encrypt_like_go/1` exactly,
  which is what the download/range/thumbnail tests use to stage the at-rest blob.
  """

  @tag_size 16

  @doc """
  Encrypts `plaintext` with AES-256-GCM. `key` must be 32 bytes, `nonce` 12 bytes.
  Returns `ciphertext <> tag` (Go `gcm.Seal` layout).
  """
  @spec encrypt(binary(), binary(), binary()) :: binary()
  def encrypt(plaintext, key, nonce)
      when byte_size(key) == 32 and byte_size(nonce) == 12 do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, <<>>, true)

    ciphertext <> tag
  end

  @doc """
  Decrypts an `ciphertext <> tag` blob produced by `encrypt/3` (or Go `gcm.Seal`).
  Returns `{:ok, plaintext}` or `{:error, :decrypt_failed}` on auth-tag mismatch.
  """
  @spec decrypt(binary(), binary(), binary()) :: {:ok, binary()} | {:error, :decrypt_failed}
  def decrypt(blob, key, nonce)
      when is_binary(blob) and byte_size(blob) >= @tag_size and
             byte_size(key) == 32 and byte_size(nonce) == 12 do
    ct_size = byte_size(blob) - @tag_size
    <<ciphertext::binary-size(^ct_size), tag::binary-size(@tag_size)>> = blob

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, <<>>, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> {:error, :decrypt_failed}
    end
  end

  def decrypt(_blob, _key, _nonce), do: {:error, :decrypt_failed}
end
