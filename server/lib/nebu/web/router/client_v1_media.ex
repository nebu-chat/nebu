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

  plug Nebu.Web.Plugs.OidcPlug
  plug :match
  plug :dispatch

  get "/download/:server_name/:media_id/:file_name" do
    Media.download(conn, server_name, media_id, file_name)
  end

  get "/download/:server_name/:media_id" do
    Media.download(conn, server_name, media_id)
  end

  get "/thumbnail/:server_name/:media_id" do
    Media.thumbnail(conn, server_name, media_id)
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"errcode" => "M_NOT_FOUND", "error" => "Unrecognized request"}))
  end
end
