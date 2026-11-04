defmodule Nebu.OAuth.SessionLifetimeLegacyFollowTest do
  @moduledoc """
  Story `session-lifetime-setting`, DECISION M3 (test review, owner decision: accept and document, do not freeze): a CHARACTERISATION test, not a wish.

  The guarantee "sessions already issued keep their ceiling" is absolute for OAuth sessions only (`matrix_sessions.session_expires_at` is stored per row). A
  LEGACY session (`auth_api = 'legacy'`) has no stored ceiling: `MatrixSessionStore.extend_in_place/3` (the background refresh worker) bounds an extension
  by `created_at + the CURRENT Matrix session lifetime`, so the setting is followed in both directions for the extension of existing legacy rows:

    * a LOWERED value stops the extension earlier,
    * a RAISED value lets the worker extend an existing row up to the new bound,
    * `expires_at` is never shortened (`GREATEST(expires_at, ...)`).

  Documented in docs/architecture/07-deployment.md ("Matrix session lifetime", checked by session_lifetime_docs_test.exs) and in the story Decisions.
  Real database; the saved lifetime is a real row (no config seam).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L

  setup do
    T.clear_oauth_config()
    L.clear_env_ttl!()
    L.delete_row!()
    user_id = T.provision_user!()
    # a legacy row that expires soon, so that every extension below is bounded by the lifetime and nothing else
    {:ok, s: T.legacy_session!(user_id, "LEGACYLT" <> T.rand(3), expires_at: DateTime.add(DateTime.utc_now(), 60, :second))}
  end

  # seconds between created_at and expires_at of the legacy row
  defp span(at) do
    %{rows: [[secs]]} = T.sql!("SELECT extract(epoch FROM expires_at - created_at)::float8 FROM matrix_sessions WHERE access_token_hash = $1", [T.token_hash(at)])
    secs
  end

  defp extend!(at, seconds_from_now), do: assert(:ok = Store.extend_in_place(at, DateTime.add(DateTime.utc_now(), seconds_from_now, :second), nil))

  test "a lowered setting bounds the extension of an existing legacy session at created_at + the new lifetime", %{s: s} do
    L.set_row!("3600")
    extend!(s.at, 7200)
    assert_in_delta span(s.at), 3600, 3
  end

  test "a raised setting lets the worker extend an existing legacy session up to the new bound; a later lowering never shortens it", %{s: s} do
    L.set_row!("3600")
    extend!(s.at, 7200)
    assert_in_delta span(s.at), 3600, 3

    L.set_row!("7200")
    extend!(s.at, 10_000)
    assert_in_delta span(s.at), 7200, 3

    L.set_row!("3600")
    extend!(s.at, 9000)
    assert_in_delta span(s.at), 7200, 3, "expires_at is never shortened by a lowered setting"
  end

  test "without a saved value the 8 hour default bounds the extension (the baseline of the characterisation)", %{s: s} do
    extend!(s.at, 40_000)
    assert_in_delta span(s.at), 28_800, 3
  end
end
