defmodule Nebu.Web.SessionConfig do
  @moduledoc """
  Configurable Nebu session-lifetime ceilings (story e2e-session-refresh-suites).

  Both the Matrix opaque-session ceiling (`Nebu.Matrix.HttpPublic`, login + `/v3/refresh`
  re-mint) and the admin session ceiling (`Nebu.Admin.Auth`) default to 8h. These defaults
  are unchanged from the previous hardcoded constants. The e2e stack shortens them via
  `NEBU_MATRIX_SESSION_TTL_SECONDS` / `NEBU_ADMIN_SESSION_TTL_SECONDS` so the silent-refresh
  loop fires inside a test window.

  `runtime.exs` parses the env vars with `parse_ttl/1` and writes the validated value to
  `config :nebu_http`. The accessors here read that config, falling back to the 8h default
  when unset — so with the env vars unset the behavior is byte-for-byte identical to before.
  """

  @default_matrix_ttl_seconds 8 * 3600
  @default_admin_ttl_seconds 8 * 60 * 60

  @doc "Live Matrix opaque-session ceiling in seconds (default 8h)."
  @spec matrix_session_ttl_seconds() :: pos_integer()
  def matrix_session_ttl_seconds do
    Application.get_env(:nebu_http, :matrix_session_ttl_seconds, @default_matrix_ttl_seconds)
  end

  @doc "Live admin session ceiling in seconds (default 8h)."
  @spec admin_session_ttl_seconds() :: pos_integer()
  def admin_session_ttl_seconds do
    Application.get_env(:nebu_http, :admin_session_ttl_seconds, @default_admin_ttl_seconds)
  end

  @doc "Default Matrix ceiling (8h) — the value used when the env var is unset."
  @spec default_matrix_ttl_seconds() :: pos_integer()
  def default_matrix_ttl_seconds, do: @default_matrix_ttl_seconds

  @doc "Default admin ceiling (8h) — the value used when the env var is unset."
  @spec default_admin_ttl_seconds() :: pos_integer()
  def default_admin_ttl_seconds, do: @default_admin_ttl_seconds

  @doc """
  Defensively parse a TTL env value. Returns `{:ok, seconds}` only for a strictly
  positive integer string; `:invalid` for `nil` / junk / non-positive values. Callers
  (runtime.exs) leave the default untouched on `:invalid` — a misconfigured env var must
  never shorten or crash the login path.
  """
  @spec parse_ttl(String.t() | nil) :: {:ok, pos_integer()} | :invalid
  def parse_ttl(nil), do: :invalid

  def parse_ttl(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :invalid
    end
  end
end
