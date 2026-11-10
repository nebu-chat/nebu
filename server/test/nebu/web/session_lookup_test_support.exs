defmodule Nebu.Web.SessionLookupTestSupport do
  @moduledoc """
  Shared test helper for tests that present a JUNK opaque access token to `OidcPlug` without a database
  (bugfix unit-tests-junk-token-503-after-lookup-fix).

  Since bugfix matrix-token-lookup-db-error-not-401 a FAILED token lookup (DB error, pool timeout, repo not started
  = no DB in the unit run) is answered `503 M_UNKNOWN` + `Retry-After`, never `401 M_UNKNOWN_TOKEN`. A unit test whose
  point is "an unknown token is a 401" therefore needs a deterministic "no such row" answer of the lookup instead of
  a missing database. `setup_no_row_lookup/0` installs it through the test-only seam
  `:nebu_http, :matrix_session_lookup_fault` = `:no_row` (compiled in only for `Mix.env() == :test`, see
  `Nebu.Matrix.Session.MatrixSessionStore`) and restores the previous value when the test ends.

  The seam is process-global: use it only from `async: false` tests (they never overlap another test module).
  Tests that assert the 503 contract of a failed lookup live in `oidc_plug_lookup_failure_test.exs` and must not use this helper.
  """

  @fault_key :matrix_session_lookup_fault

  @doc "Makes every access-token lookup answer \"no such row\" for the rest of the calling test; the previous seam value is restored on exit."
  @spec setup_no_row_lookup() :: :ok
  def setup_no_row_lookup do
    prior = Application.fetch_env(:nebu_http, @fault_key)
    Application.put_env(:nebu_http, @fault_key, :no_row)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:nebu_http, @fault_key, value)
        :error -> Application.delete_env(:nebu_http, @fault_key)
      end
    end)

    :ok
  end
end
