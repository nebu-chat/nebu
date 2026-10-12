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

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  # The /admin subtree is served by Nebu.Admin.Endpoint, which runs its own
  # Plug.Parsers (urlencoded/multipart/json). Do NOT pre-read the body here, or the
  # admin endpoint's parser short-circuits and form POSTs lose their params (CSRF).
  def call(%Plug.Conn{path_info: ["admin" | _]} = conn, _opts), do: conn

  def call(conn, _opts) do
    Plug.Parsers.call(conn, @parser_opts)
  rescue
    e in Plug.Parsers.RequestTooLargeError ->
      # The account-data PUT routes (exact shapes, global + room) and the room-tag PUT routes
      # answer 413 M_TOO_LARGE themselves (they check :body_too_large); every other route —
      # including paths that merely contain an `account_data` / `tags` segment — keeps Plug's
      # default (re-raise → 413).
      if Nebu.Web.Plugs.RawBodyReader.opaque_content_put?(conn) do
        %{conn | body_params: %{}}
        |> Plug.Conn.assign(:body_too_large, true)
      else
        reraise e, __STACKTRACE__
      end

    Plug.Parsers.ParseError ->
      # Malformed JSON body. Mark it and continue; the matched handler decides
      # the response (login → 400 M_NOT_JSON). body_params stays empty.
      %{conn | body_params: %{}}
      |> Plug.Conn.assign(:json_parse_error, true)
  end
end
