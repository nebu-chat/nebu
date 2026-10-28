defmodule Nebu.Web.Plugs.JsonBody do
  @moduledoc """
  Runs `Plug.Parsers` (JSON) but converts a malformed-body
  `Plug.Parsers.ParseError` into a tagged connection instead of letting it
  propagate as a 500-class crash.

  Matrix clients expect `400 {"errcode":"M_NOT_JSON"}` for a body that is not
  valid JSON (e.g. `POST /_matrix/client/v3/login`). `Plug.Parsers` raises on a
  malformed body, and `Plug.ErrorHandler` re-raises after running its callback —
  so neither is usable for "respond 400 and stop". This plug catches the parse
  error here, assigns `conn.assigns[:json_parse_error] = true`, and leaves
  `conn.body_params = %{}` so downstream routing proceeds normally; body-reading
  handlers (login) check the flag and return the Matrix 400 envelope themselves.

  A hard body-size cap (`length`) is enforced as defense-in-depth so an oversized
  login/createRoom payload cannot exhaust memory (SEC directive).

  ## Why the `/admin` subtree is skipped

  This plug runs at the top of the single Bandit listener's `Nebu.Web.Router`,
  BEFORE `:match` dispatches the `/admin/*` subtree into `Nebu.Admin.Endpoint`.
  That endpoint owns its own full `Plug.Parsers` chain (`:urlencoded`,
  `:multipart`, `:json`) — the Admin UI's only plain HTTP form POST
  (`/admin/bootstrap/select-claim`) sends `application/x-www-form-urlencoded`.

  Running this JSON-only parser (with `pass: ["*/*"]`) over that urlencoded POST
  moved `conn.body_params` away from `%Plug.Conn.Unfetched{}` WITHOUT reading or
  parsing the urlencoded body. The admin endpoint's `Plug.Parsers` then
  short-circuited (it only parses while `body_params` is still `Unfetched`), so the
  form's `_csrf_token` field was never decoded and `protect_from_forgery` raised
  `Plug.CSRFProtection.InvalidCSRFTokenError` (masked in prod by a secondary
  RenderErrors MatchError). We therefore leave the body untouched for `/admin/*`
  and let the admin endpoint parse it. Matrix/media routes are unaffected.
  """
  @behaviour Plug

  @parser_opts Plug.Parsers.init(
                 parsers: [:json],
                 json_decoder: Jason,
                 length: 1_000_000,
                 body_reader: {Nebu.Web.Plugs.RawBodyReader, :read_body, []},
                 pass: ["*/*"]
               )

  # POST /oauth2/register is UNAUTHENTICATED and its rate limiter runs only after this plug has
  # parsed the body, so it gets a much lower cap than the 1 MB default (a legitimate registration
  # is < 60 KB: at most 20 redirect URIs + 4 URIs of <= 2048 bytes). Oversize is flagged
  # (`:body_too_large`) and answered by `Nebu.OAuth.Http` in the OAuth error shape.
  @register_parser_opts Plug.Parsers.init(
                          parsers: [:json],
                          json_decoder: Jason,
                          length: 131_072,
                          body_reader: {Nebu.Web.Plugs.RawBodyReader, :read_body, []},
                          pass: ["*/*"]
                        )

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  # The /admin subtree is served by Nebu.Admin.Endpoint, which runs its own
  # Plug.Parsers (urlencoded/multipart/json). Do NOT pre-read the body here, or the
  # admin endpoint's parser short-circuits and form POSTs lose their params (CSRF).
  def call(%Plug.Conn{path_info: ["admin" | _]} = conn, _opts), do: conn

  # GET /oauth2/authorize parses its RAW query string itself (story
  # oauth-authorize-idp-delegation-code, D13: duplicates and malformed percent-encoding must be
  # answered with an HTML page, not with Plug.Parsers' InvalidQueryError). It has no body.
  def call(%Plug.Conn{path_info: ["oauth2", "authorize" | _]} = conn, _opts), do: conn

  # POST /oauth2/token (story oauth-token-endpoint, T23) reads and parses its RAW
  # application/x-www-form-urlencoded body itself (16 KiB cap, duplicates and malformed
  # percent-encoding are `invalid_request`), exactly once. `body_params` stays `Unfetched`, so
  # RequestLogger never logs the token request body.
  def call(%Plug.Conn{path_info: ["oauth2", "token" | _]} = conn, _opts), do: conn

  # POST /oauth2/revoke (story oauth-token-revocation-logout, R8) is read the same way (shared
  # `Nebu.OAuth.FormPost.parse/1`): the `token` must never be parsed into `body_params`, which
  # RequestLogger would capture.
  def call(%Plug.Conn{path_info: ["oauth2", "revoke" | _]} = conn, _opts), do: conn

  # The account page (story oauth-account-management, A4): its POST handlers read their raw
  # form body exactly once through `Nebu.OAuth.FormPost.parse/1` (16 KiB, form-encoded only, duplicates
  # refused) and answer parse errors as the HTML `invalid_request` page; `body_params` stays `Unfetched`,
  # so `RequestLogger` never captures a CSRF token. GET /account parses its RAW query itself.
  def call(%Plug.Conn{path_info: ["account" | _]} = conn, _opts), do: conn

  # The consent page (story oauth-authorize-freshness, FR7): `POST /oauth2/consent` reads its RAW form body
  # exactly once through `Nebu.OAuth.FormPost.parse/1` (16 KiB, form-encoded only, duplicates refused),
  # so `body_params` stays `Unfetched` and `RequestLogger` never captures the CSRF token. GET parses
  # nothing (no query is read).
  def call(%Plug.Conn{path_info: ["oauth2", "consent" | _]} = conn, _opts), do: conn

  # The legacy SSO confirmation page (story legacy-sso-redirect-confirmation, G3-3, D9 / D11): `POST
  # /_matrix/client/v3/login/sso/confirm` reads its RAW form body exactly once through `Nebu.OAuth.parse_form_post/1`
  # (16 KiB, form-encoded only, duplicates refused), so `body_params` stays `Unfetched` and `RequestLogger` never
  # captures the CSRF token (a JSON body is not parsed either: `400 invalid_request`).
  def call(%Plug.Conn{path_info: ["_matrix", "client", "v3", "login", "sso", "confirm" | _]} = conn, _opts), do: conn

  def call(%Plug.Conn{path_info: ["oauth2", "register" | _]} = conn, _opts),
    do: parse(conn, @register_parser_opts)

  def call(conn, _opts), do: parse(conn, @parser_opts)

  defp parse(conn, parser_opts) do
    Plug.Parsers.call(conn, parser_opts)
  rescue
    e in Plug.Parsers.RequestTooLargeError ->
      # The account-data PUT routes (exact shapes, global + room) and the room-tag PUT routes
      # answer 413 M_TOO_LARGE themselves (they check :body_too_large); POST /oauth2/register
      # answers 413 in the OAuth error shape. Story event-size-limit (D7): every other Matrix client route
      # (`/_matrix/*`) answers the Matrix envelope here (413 M_TOO_LARGE, application/json; the CORS headers
      # set by the `:cors` plug stay on the response) and halts, so no route runs and nothing is written. The
      # cap itself is unchanged. Every other path keeps Plug's default (re-raise -> Bandit's bodiless 413).
      cond do
        Nebu.Web.Plugs.RawBodyReader.opaque_content_put?(conn) or oauth_register?(conn) ->
          %{conn | body_params: %{}}
          |> Plug.Conn.assign(:body_too_large, true)

        matrix_route?(conn) ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          # the unread rest of the body is not drained: close the connection after the answer (what Bandit's own bodiless 413 does)
          |> Plug.Conn.put_resp_header("connection", "close")
          |> Plug.Conn.send_resp(413, Jason.encode!(%{"errcode" => "M_TOO_LARGE", "error" => "Request body is too large"}))
          |> Plug.Conn.halt()

        true ->
          reraise e, __STACKTRACE__
      end

    Plug.Parsers.ParseError ->
      # Malformed JSON body. Mark it and continue; the matched handler decides
      # the response (login → 400 M_NOT_JSON). body_params stays empty.
      %{conn | body_params: %{}}
      |> Plug.Conn.assign(:json_parse_error, true)
  end

  defp oauth_register?(%Plug.Conn{path_info: ["oauth2", "register" | _]}), do: true
  defp oauth_register?(_conn), do: false

  defp matrix_route?(%Plug.Conn{path_info: ["_matrix" | _]}), do: true
  defp matrix_route?(_conn), do: false
end
