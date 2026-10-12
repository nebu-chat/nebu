defmodule Nebu.Web.Plugs.RequestLogger do
  @moduledoc """
  Logs every HTTP request/response at INFO level (method, path, status,
  duration_ms, request_id), and — ONLY when the effective `Logger` level
  currently allows `:debug` output — additionally captures the (redacted)
  request and response bodies at DEBUG level.

  ## Scope (enhanced-logging/matrix-payload-debug-logging, AC1-AC3, AC9-AC10)

  This story implements ONLY the payload-capture + redaction layer. The
  enable/disable toggle (env var or admin UI) is a SEPARATE story — there is
  no such toggle here. Instead, this plug always attempts a `Logger.debug/1`
  call carrying the redacted payload; Elixir's `Logger` already no-ops that
  call for free (compiled out via `Logger.compare_levels/2` under the hood,
  or filtered at emit-time) whenever the configured level is above `:debug`.
  This means payload logging is naturally gated on
  `Logger.level() in [:debug]` (or lower, i.e. never in this project) without
  any bespoke flag — exactly matching `Logger.configure(level: :debug)` /
  `Logger.configure(level: :info)` toggling used in tests and available to
  operators today via runtime `Logger.configure/1`.

  All payload logging is routed through
  `Nebu.Web.Plugs.RequestLogger.PayloadRedactor.redact_payload/1` (AC4-AC7),
  so credentials/secrets and chat message content never reach the log
  output, even at DEBUG level (ADR-022 compliance constraint).
  """
  @behaviour Plug

  require Logger

  alias Nebu.Web.Plugs.RequestLogger.PayloadRedactor
  alias Nebu.Web.LogStore.RouteNormalizer

  # security review 2026-07-05 (cycle 5 re-verify, F1-R): the Matrix write
  # path — `PUT .../rooms/{roomId}/send/{eventType}/{txnId}` and `PUT
  # .../rooms/{roomId}/state/{eventType}[/{stateKey}]` — sends the RAW event
  # `content` object as the top-level request body, with NO `content`
  # wrapper. `PayloadRedactor`'s cycle-5 fixed field-name list
  # (`@always_content_keys`) cannot be exhaustive for Matrix's
  # open/extensible event schema (`m.location.geo_uri`, custom/vendor
  # fields, poll text, `m.room.encrypted.ciphertext`), so these two routes
  # are matched here (by `conn.request_path`, immutable regardless of
  # `forward`'s path_info-stripping — see `Nebu.Web.Router`'s
  # `forward "/_matrix", to: Nebu.Web.Router.Protected`) and their request
  # bodies are redacted with `in_content?: true` instead of the default.
  # Every other route (including the read path — `/sync`, `/messages`,
  # etc. — where content IS already wrapped under a `content` key) keeps
  # the unchanged default (`in_content?: false`).
  @send_event_path_regex ~r{^/_matrix/client/v\d+/rooms/[^/]+/send/[^/]+/[^/]+$}
  @state_event_path_regex ~r{^/_matrix/client/v\d+/rooms/[^/]+/state/[^/]+(?:/[^/]*)?$}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    start_ms = System.monotonic_time(:millisecond)

    # ORDERING DEPENDENCY: Nebu.Web.Plugs.RequestId MUST run before this plug in the
    # router pipeline. RequestId sets the "x-request-id" response header; we read it here.
    # If RequestId were placed after RequestLogger, request_id would be nil in the log line.
    request_id = Plug.Conn.get_resp_header(conn, "x-request-id") |> List.first()

    # enhanced-logging/operational-log-store (AC5): a normalized route
    # template, computed once from the (stable throughout the pipeline)
    # request path — logged as its own field AND reused for the `path` field
    # below, so the raw, un-normalized path (which may embed a Matrix room
    # ID/user ID/room alias) never appears in the base log line at all.
    route_template = RouteNormalizer.normalize_route(conn.request_path)

    # enhanced-logging/operational-log-store (AC4/AC5, code-review M1):
    # propagate BOTH request_id AND route_template to Logger.metadata/1
    # EARLY (synchronously, here in call/2 itself — not deferred into the
    # before_send callback below) so ALL subsequent Logger.* calls in THIS
    # process automatically carry them (e.g. Nebu.Repo.QueryTelemetry's
    # Logger.debug/1 call, fired from within the same request-handling
    # process) AND so `Nebu.Web.LogStore.Handler.parse_log_event/1` (which
    # reads route_template/request_id EXCLUSIVELY from the `:logger` event's
    # `meta` field, never from rendered message text) actually sees a
    # populated `route_template` for the base INFO log line below —
    # previously only request_id was ever set here, leaving the persisted
    # `operational_logs.route_template` column permanently NULL for every
    # HTTP-sourced entry. Logger.metadata/1 is per-process — a Task.start/1'd
    # async path does NOT inherit it (documented limitation, AC4 caveat; see
    # request_logger_test.exs's dedicated test for this).
    if request_id do
      Logger.metadata(request_id: request_id, route_template: route_template)
    else
      Logger.metadata(route_template: route_template)
    end

    # AC4: capture (and redact) the Authorization header up front, before any
    # downstream plug/body parsing runs — the header itself never contains
    # message content, only credentials, so it is safe to read immediately.
    auth_header = Plug.Conn.get_req_header(conn, "authorization") |> List.first()

    Plug.Conn.register_before_send(conn, fn conn ->
      duration_ms = System.monotonic_time(:millisecond) - start_ms

      base_fields = %{
        method: conn.method,
        path: route_template,
        status: conn.status,
        duration_ms: duration_ms,
        request_id: request_id,
        route_template: route_template
      }

      # enhanced-logging/admin-logs-monitoring-view (test-review finding #4):
      # method/status/duration_ms previously only ever reached the rendered
      # `message` text (via Logger.info(base_fields)'s `{:report, report}`
      # handling in Nebu.Web.LogStore.Handler.render_msg/1, which just
      # `inspect/1`s the whole map) — never the `:logger` event's own `meta`,
      # the ONLY place Handler.parse_log_event/1's `safe_metadata/1` reads
      # from to populate the persisted/broadcast `metadata` column/field.
      # This blocked AC6 of admin-logs-monitoring-view (status badge,
      # method+path, duration display) for every HTTP-sourced entry.
      # Setting them via Logger.metadata/1 HERE (immediately before the
      # Logger.info/1 call below, in the same process) makes them flow
      # structurally through the existing metadata-capture path with no
      # change needed to Handler itself. request_id/route_template are
      # already set (in call/2, above) and continue to be stripped back out
      # by Handler's `@drop_meta_keys` since they are already their own
      # top-level columns/fields.
      Logger.metadata(method: conn.method, status: conn.status, duration_ms: duration_ms)

      # enhanced-logging/war-room-mode (design-decisions.md #5, AC9): the
      # War Room's user_id/device_id filter has nothing to match against
      # unless SOME code path puts these into Logger.metadata/1 (Handler's
      # safe_metadata/1 already carries through any metadata key it doesn't
      # explicitly drop). register_before_send/2's callback runs AFTER the
      # whole plug pipeline — including Nebu.Web.Plugs.OidcPlug, which (for
      # authenticated Matrix routes) assigns conn.assigns.current_user /
      # conn.assigns.device_id — so these assigns are already populated
      # here regardless of plug ordering. For unauthenticated/public routes
      # they are simply absent -> nil -> never satisfies a filter that
      # requires them (correct: a filter is AND-across-present-fields,
      # never satisfied by nil on either side, per AC9).
      #
      # Security note (code-review MAJOR-1 fix): `RequestLogger` is mounted
      # in the TOP-LEVEL `Nebu.Web.Router` (see moduledoc), which also serves
      # `/admin/*` via `dispatch_admin` — on those routes,
      # `Nebu.Admin.Auth.fetch_current_user/2` assigns `conn.assigns.current_user`
      # to a MAP (`"sub"`, `"email"`, `"admin"`, `"matrix_user_id"`,
      # session-timing fields), NOT a bare user_id string. Passing that raw
      # map to `Logger.metadata/1` would let `Handler.safe_metadata/1`
      # (which recurses into maps) leak the admin's EMAIL into the
      # persisted/broadcast `operational_logs.metadata["user_id"]` field —
      # a PII leak, not the identifier-for-accountability case this note
      # originally justified. `extract_user_id/1` below reduces
      # `conn.assigns.current_user` to a bare identifier string (or nil)
      # regardless of shape BEFORE it ever reaches `Logger.metadata/1`:
      # already-a-string (Matrix routes) passes through unchanged; a map
      # (admin routes) yields `"matrix_user_id"` (preferred) or `"sub"` —
      # never `"email"` or the whole map; anything else -> nil.
      #
      # Security note: user_id/device_id are IDENTIFIERS, not chat message
      # content or credentials — the same category already logged in
      # plaintext elsewhere for accountability (e.g.
      # Nebu.Compliance.AuditLogEntry.actor_user_id). Consistent with the
      # "No Sensitive Data in Logs" LAW (tokens/credentials + message
      # content — not identifiers used for legitimate operational
      # scoping/accountability).
      Logger.metadata(
        user_id: extract_user_id(conn.assigns[:current_user]),
        device_id: conn.assigns[:device_id]
      )

      Logger.info(base_fields)

      # DEBUG-level payload capture (AC1-AC3): naturally gated on the
      # currently effective Logger level — no bespoke enable/disable flag
      # exists yet (that is a separate story, AC9). `Logger.debug/1` is a
      # no-op when the level is above :debug, so this call is cheap and safe
      # to always make.
      Logger.debug(fn ->
        payload_fields = %{
          request_body: redacted_request_body(conn),
          response_body: redacted_response_body(conn),
          auth_header: redact_auth_header(auth_header),
          query_string: redacted_query_string(conn)
        }

        base_fields
        |> Map.merge(payload_fields)
        |> Jason.encode!()
      end)

      conn
    end)
  end

  # Request body: `Nebu.Web.Plugs.JsonBody` (which runs downstream of this
  # plug) already decodes JSON request bodies into `conn.body_params`. By the
  # time this `before_send` callback runs, that decoding has happened, so we
  # read the already-decoded map rather than re-reading/re-parsing the raw
  # body (which Plug does not support reading twice).
  # code-review MAJOR-1: reduces `conn.assigns.current_user` to a bare
  # identifier string (or nil) regardless of shape, so `Logger.metadata/1`
  # (and therefore the persisted/broadcast operational_logs metadata) NEVER
  # sees the raw admin-session map — only ever a plain user_id string.
  #   - Matrix routes (`Nebu.Web.Plugs.OidcPlug`): `current_user` IS ALREADY
  #     a bare string -> pass through unchanged.
  #   - Admin routes (`Nebu.Admin.Auth.fetch_current_user/2`): `current_user`
  #     is a map with string keys -> prefer `"matrix_user_id"`, else `"sub"`.
  #     NEVER `"email"`, and NEVER the whole map.
  #   - Anything else (nil, unexpected shape) -> nil.
  defp extract_user_id(user_id) when is_binary(user_id), do: user_id

  defp extract_user_id(%{"matrix_user_id" => matrix_user_id})
       when is_binary(matrix_user_id) and matrix_user_id != "",
       do: matrix_user_id

  defp extract_user_id(%{"sub" => sub}) when is_binary(sub) and sub != "", do: sub

  defp extract_user_id(_other), do: nil

  defp redacted_request_body(conn) do
    if account_data_content?(conn), do: nil, else: redacted_request_body_params(conn)
  end

  # Account data (global + room scope) and the room-tag routes are opaque, client-defined USER
  # CONTENT (tag orders / fields, markers, secret-storage blobs): neither the request nor the response body is ever captured, not
  # even redacted (Logging Law: no user content in logs).
  defp account_data_content?(conn) do
    Nebu.Web.Plugs.RawBodyReader.opaque_content_shape?(conn.request_path)
  end

  defp redacted_request_body_params(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        nil

      params when is_map(params) ->
        if write_path_content_body?(conn) do
          PayloadRedactor.redact_payload(params, in_content?: true)
        else
          PayloadRedactor.redact_payload(params)
        end

      _ ->
        nil
    end
  end

  # F1-R: true for the Matrix write-path routes whose request body IS the
  # raw top-level event `content` object (no `content` wrapper) — see the
  # module attributes above and `PayloadRedactor.redact_payload/2`'s
  # `in_content?: true` option. `conn.request_path` (not `conn.path_info`)
  # is used because `path_info` is mutated by `Plug.Router`'s `forward`
  # (which strips the matched prefix) by the time this `before_send`
  # callback runs, whereas `request_path` reflects the original, full
  # request path throughout — the same field `base_fields.path` already
  # relies on above.
  defp write_path_content_body?(conn) do
    Regex.match?(@send_event_path_regex, conn.request_path) or
      Regex.match?(@state_event_path_regex, conn.request_path)
  end

  # Response body: `conn.resp_body` is still available on the conn passed
  # into the `before_send` callback (set by `send_resp/3` et al.) — the
  # adapter writes it to the socket AFTER `before_send` callbacks run, so we
  # can safely read it here without needing any special capture pattern.
  #
  # code-review m4: only attempt `Jason.decode/1` when the response declares
  # a JSON content-type. Binary media downloads (images, files) always fail
  # to parse as JSON — this is a cheap short-circuit to avoid wasted decode
  # work on every such response during a live DEBUG session (no correctness
  # impact either way, since `Jason.decode/1` failing already yields `nil`
  # via the `with`/`else` below; this is purely an efficiency guard, and the
  # whole call is already lazy via `Logger.debug(fn -> ... end)`).
  defp redacted_response_body(conn) do
    with false <- account_data_content?(conn),
         true <- json_content_type?(conn),
         body when is_binary(body) <- conn.resp_body,
         {:ok, decoded} <- Jason.decode(body) do
      PayloadRedactor.redact_payload(decoded)
    else
      _ -> nil
    end
  end

  defp json_content_type?(conn) do
    conn
    |> Plug.Conn.get_resp_header("content-type")
    |> List.first()
    |> case do
      content_type when is_binary(content_type) -> String.contains?(content_type, "json")
      _ -> false
    end
  end

  # AC4: the Authorization header, when present, is a credential — its
  # entire value (not just the token part) is masked, regardless of scheme.
  #
  # code-review m1: routed through `PayloadRedactor.redact_payload/1` (the
  # SAME credential-key matching used for body/query-string redaction)
  # instead of a second, independently-hardcoded "just always redact"
  # implementation — avoids two copies of the "what counts as a credential"
  # concept drifting apart over time.
  defp redact_auth_header(nil), do: nil

  defp redact_auth_header(value) do
    %{"authorization" => value}
    |> PayloadRedactor.redact_payload()
    |> Map.get("authorization")
  end

  # code-review M2: the deprecated Matrix `?access_token=` query-param auth
  # style is still supported by some legacy clients. `PayloadRedactor`
  # already has string-level redaction logic for this pattern
  # (`redact_string/1`), but until now `RequestLogger` never actually read
  # `conn.query_string` anywhere, so that MUST was unit-tested in isolation
  # only — never exercised end-to-end. Capturing (and redacting) it here
  # closes that gap and gives operators visibility into query-string-only
  # requests (e.g. legacy `?access_token=`-authenticated clients) without
  # ever leaking the token itself.
  defp redacted_query_string(conn) do
    case conn.query_string do
      "" -> nil
      qs -> PayloadRedactor.redact_payload(qs)
    end
  end
end
