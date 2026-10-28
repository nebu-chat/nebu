defmodule Nebu.Web.Router.ClientV1Media do
  @moduledoc """
  Authenticated Matrix Client-Server `v1` media endpoints
  (`/_matrix/client/v1/media/download`, `/_matrix/client/v1/media/thumbnail`),
  forwarded here from `Nebu.Web.Router` under the `/_matrix/client/v1/media`
  prefix (bugfix-fix-matrix-client-v1-media-routes).

  Deliberately a SEPARATE router module from `Nebu.Web.Router.Media` (the
  `/_matrix/media` v3 router), even though both call the exact same
  `Nebu.Media.download/2,3` / `Nebu.Media.thumbnail/3` handler functions.

  Code-review (cycle 1) flagged that forwarding `/_matrix/client/v1/media`
  to `Nebu.Web.Router.Media` directly made routes cross-reachable that were
  never in this story's scope (AC1-AC3 only cover `download`/`thumbnail`):
  because `forward` strips the matched prefix before dispatch, and
  `Nebu.Web.Router.Media` matches on the SUFFIX after stripping, sharing that
  router meant:

    * `/_matrix/media/download/...` / `/_matrix/media/thumbnail/...` (no
      `/v3/` segment) became reachable via the un-versioned clauses added for
      `v1` — an unintended, unreviewed alias.
    * `/_matrix/client/v1/media/v3/{upload,thumbnail,download,preview_url}`
      became reachable via the `v1` prefix — including `preview_url`, the
      SSRF-amplifier outbound-fetch endpoint that has its own dedicated rate
      limit and was never meant to gain a second URL.

  This router has ONLY the three `download`/`thumbnail` clauses this story
  scoped itself to, plus its own `OidcPlug` pipeline and its own generic 404
  catch-all — it cannot reach `upload`/`preview_url`/the `v3` tree at all,
  because those route clauses simply do not exist here.

  `Nebu.Web.Plugs.OidcPlug` runs in this router's pipeline (test-review MIN-2
  parity with `Nebu.Web.Router.Media`: every media route MUST sit behind
  OidcPlug). On success it assigns `conn.assigns.current_user`, which
  `Nebu.Media` uses as the trusted identity for the membership check.

  No rate limiting here, matching the un-rate-limited `v3`
  `download`/`thumbnail` clauses in `Nebu.Web.Router.Media` (only `upload`
  and `preview_url` carry explicit `RateLimit` plugs, and neither of those
  endpoints exists in this router).
  """
  use Plug.Router

  alias Nebu.Media

  # Pipeline (story oauth-room-summary-unrecognized, RU10): :match runs BEFORE authentication so the
  # catch-all (marked `nebu_unrecognized: true`) answers an unimplemented endpoint with a spec
  # `M_UNRECOGNIZED` without a credential check; every real route still runs the OidcPlug.
  plug :match
  plug :authenticate
  plug :dispatch

  @doc """
  Runs `Nebu.Web.Plugs.OidcPlug` for every matched route; skipped ONLY when the catch-all marked the conn
  (`conn.private[:nebu_unrecognized] === true`, strict boolean, fail closed).
  """
  @spec authenticate(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def authenticate(%Plug.Conn{private: %{nebu_unrecognized: true}} = conn, _opts), do: conn
  def authenticate(conn, _opts), do: Nebu.Web.Plugs.OidcPlug.call(conn, Nebu.Web.Plugs.OidcPlug.init([]))

  get "/download/:server_name/:media_id/:file_name" do
    Media.download(conn, server_name, media_id, file_name)
  end

  get "/download/:server_name/:media_id" do
    Media.download(conn, server_name, media_id)
  end

  get "/thumbnail/:server_name/:media_id" do
    Media.thumbnail(conn, server_name, media_id)
  end

  # Fall-through (RU9 - RU11): 404 for an unknown path, 405 + Allow when another method routes here.
  match _, private: %{nebu_unrecognized: true} do
    Nebu.Web.Unrecognized.respond(conn, allowed_methods(conn))
  end

  # The methods this router has a real clause for at the request path (a probe selects a clause, it never
  # dispatches; the marker is removed first, RU11).
  defp allowed_methods(conn) do
    path = Plug.Router.Utils.decode_path_info!(conn)
    conn = %{conn | private: Map.delete(conn.private, :nebu_unrecognized)}

    Nebu.Web.Unrecognized.probe(conn, fn c ->
      do_match(c, c.method, path, c.host).private[:nebu_unrecognized] !== true
    end)
  end
end
