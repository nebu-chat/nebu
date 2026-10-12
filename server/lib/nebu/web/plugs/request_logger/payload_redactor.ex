defmodule Nebu.Web.Plugs.RequestLogger.PayloadRedactor do
  @moduledoc """
  Two-category redaction layer for `Nebu.Web.Plugs.RequestLogger` DEBUG-level
  payload logging (enhanced-logging/matrix-payload-debug-logging).

  Both categories are equally non-negotiable per ADR-022 / the project's
  compliance-native posture:

    1. **Credentials/secrets** (`password`, `new_password`, `access_token`,
       `refresh_token`, `client_secret`, `id_access_token`, the generic UIAA
       `auth.token`/`auth.session` fields, the deprecated `?access_token=`
       query-param, and the `Authorization` HTTP header, matched
       case-insensitively) → replaced with `"***REDACTED***"`.

    2. **Chat message content** — user-generated text, replaced with
       `"***MESSAGE_CONTENT***"`. Detected by FIELD NAME at ANY depth,
       regardless of whether the field happens to be nested under a
       `content`/`prev_content` wrapper — the same principle already used
       for Category 1's credential-key detection (security review
       2026-07-05, F1: Matrix write-path requests, e.g. `PUT
       .../send/{eventType}/{txnId}` and `PUT .../state/{eventType}/{stateKey}`,
       send the event content as the RAW TOP-LEVEL request body, with no
       `content` wrapper at all — a purely structural "only redact inside
       `content`" check misses this entirely):

       * A fixed set of field names (`body`, `formatted_body`, `filename`,
         `topic`, `name`, `displayname`, `reason`) are ALWAYS treated as
         content, at any depth, wrapped or not.
       * Additionally, when walking the direct children of a `content`/
         `prev_content` object, any OTHER field not on the structural
         metadata allowlist (`msgtype`, `url`, `format`, `algorithm`,
         `sender_key`, `device_id`, `session_id`, `info`, `avatar_url`,
         `membership`) is also treated as content — this catches
         event-type-specific/custom fields (e.g. `ciphertext`,
         `com.example.custom_event`'s own fields) without an event-type
         allowlist (AC7).
       * `m.relates_to` is special-cased at any depth (F2): instead of being
         treated as blanket metadata (which shadowed its own `key` child —
         the user-chosen reaction emoji/text), it is always recursed into
         via `redact_relation_map/1`, masking `key` while preserving
         `rel_type`/`event_id`.
       * `redact_payload/2` accepts `in_content?: true` (security review
         2026-07-05, cycle 5 re-verify, F1-R): the fixed field-name list
         above cannot be exhaustive for Matrix's open/extensible event
         schema (e.g. `m.location.geo_uri`, custom/vendor fields, poll
         text, `m.room.encrypted.ciphertext`), so route-aware callers that
         KNOW a request body is itself a raw `content` object with no
         wrapper (`RequestLogger`, for the `send`/`state` write-path
         routes) opt into treating EVERY non-metadata top-level field as
         content, the same catch-all the read path already gets for free
         via its `content` wrapper.

  Additionally, per Matrix's `m.login.token` login type, a top-level `token`
  field (the actual credential carried by that login flow, distinct from the
  UIAA `auth.token` stage field and from `access_token`/`refresh_token`) is
  redacted at ANY depth, same as `password`/`access_token`/`refresh_token`
  (CI-gate cycle-1 bug 1).

  This module is a pure function (`redact_payload/1`) with no side effects —
  it does not touch the network, the DB, or any other Nebu domain (ADR-020:
  this stays inside `Nebu.Web`, no cross-domain calls).

  `redact_payload/1` accepts:

    * `nil` — returned unchanged.
    * a `map` (decoded JSON, e.g. a Matrix request/response body, or a
      headers map) — walked recursively and redacted in place.
    * a `binary` — treated as an OPAQUE string, never `Jason.decode`d and
      never speculatively reinterpreted as structured data. It is inspected
      only for a narrow set of recognisable `key=value` (query-string/
      form-encoded) and `"key": "value"` (malformed/unparseable JSON-ish
      fragment) credential/content patterns — e.g. the deprecated
      `access_token=...` query-param — via cheap, literal-substring-gated
      regex substitutions (code-review m5; see `redact_string/1`). This keeps
      raw media upload/download bytes (AC-adjacent Oracle requirement) and
      form-encoded/malformed-JSON bodies safe to pass through this function
      without risk of crashing or of fabricating JSON structure that was
      never legitimately parsed, while still scrubbing recognisable secrets.
    * any other term (e.g. a list at the top level) — walked recursively,
      same as a nested value inside a map.
  """

  @redacted "***REDACTED***"
  @message_content "***MESSAGE_CONTENT***"

  # Credential/secret keys (Category 1). Matched case-insensitively against
  # binary map keys, at ANY depth (recursive, same as password/access_token/
  # refresh_token). `token` is included here (not just under `auth`) because
  # Matrix's `m.login.token` login type carries the actual credential in a
  # TOP-LEVEL `token` field — distinct from the UIAA-scoped `auth.token`/
  # `auth.session` handling below, which is additive and still only applies
  # inside a UIAA `auth` object (`session` alone, outside `auth`, is NOT
  # treated as a credential — see `uiaa_credential_key?/1`).
  #
  # `new_password` (code-review cycle-2, M1): `POST
  # /_matrix/client/v3/account/password` carries the new plaintext password
  # under this key (distinct from `password`, which that same endpoint uses
  # for the CURRENT password / UIAA re-auth) — an Oracle MUST-listed
  # credential field.
  #
  # `client_secret` / `id_access_token` (security review 2026-07-05, F4):
  # Matrix 3PID `requestToken` flows carry a client-chosen `client_secret`,
  # and identity-server-mediated 3PID binding carries an `id_access_token`
  # (an identity-server bearer token) — both are credentials. Added
  # defensively even though the specific 3PID/identity-server request flow
  # is not fully implemented in Nebu's router today, since the field names
  # could still appear in a request body this plug receives and logs.
  @credential_keys ~w(
    password new_password access_token refresh_token token
    client_secret id_access_token
  )

  # Field names that are ALWAYS message content (user-generated text), at
  # ANY depth, regardless of whether they happen to be nested under a
  # `content`/`prev_content` wrapper (security review 2026-07-05, F1: the
  # Matrix write path — send/setState — puts event content at the TOP LEVEL
  # of the request body, with no wrapper at all). Detected by field name,
  # the same principle `credential_key?/1` already uses for Category 1.
  @always_content_keys ~w(body formatted_body filename topic name displayname reason)

  # Keys inside a Matrix `content` object that are structural/system metadata
  # — NOT user-generated text — and must therefore survive redaction. Every
  # other key found inside `content` is treated as message content per AC7's
  # "not a system/metadata field" rule (no event-type allowlist).
  #
  # `m.relates_to` and `reason` are deliberately NOT here (security review
  # 2026-07-05, F2/F3): `m.relates_to` is handled by its own dedicated
  # field-name check (`relates_to_key?/1`, always recursed into via
  # `redact_relation_map/1`, never blanket-skipped as metadata), and `reason`
  # is genuine user-generated free text (kick/ban/redaction reason) — it is
  # covered by `@always_content_keys` instead.
  @content_metadata_keys ~w(
    msgtype url format algorithm sender_key device_id session_id
    info avatar_url membership
  )

  @doc """
  Recursively redacts credentials/secrets (Category 1) and chat message
  content (Category 2) from a decoded JSON map, a list, or a string.

  Pure function — safe to call in isolation (AC10), idempotent, and safe on
  `nil`/empty/binary/malformed input (never raises).

  Equivalent to `redact_payload(payload, [])` — see `redact_payload/2` for
  the `in_content?: true` option used by route-aware write-path callers
  (security review 2026-07-05, cycle 6 re-verify, F1-R).
  """
  @spec redact_payload(term()) :: term()
  def redact_payload(payload), do: redact_payload(payload, [])

  @doc """
  Same as `redact_payload/1`, with an `opts` keyword list. Supports:

    * `in_content?: true` — seeds the TOP-LEVEL recursion as though the
      given map/list were already the direct children of a Matrix event
      `content` object, instead of the default `false`.

  ## Why this exists (security review 2026-07-05, cycle 5 re-verify, F1-R)

  Cycle 5 closed the F1 write-path leak for a FIXED set of common field
  names (`@always_content_keys`, checked at any depth regardless of
  `in_content?`). But Matrix's write-path endpoints — `PUT
  .../rooms/{roomId}/send/{eventType}/{txnId}` and `PUT
  .../rooms/{roomId}/state/{eventType}[/{stateKey}]` — send the RAW event
  `content` object as the top-level request body, with NO `content`
  wrapper at all. Matrix's event schema is open/extensible (custom/vendor
  fields, `m.location.geo_uri`, poll question/answer text,
  `m.room.encrypted.ciphertext`), so a fixed field-name list can never be
  exhaustive: any content field NOT on that list still fell through
  `redact_map/2`'s "non-metadata inside `content` ⇒ content" catch-all,
  because that catch-all is gated on `in_content? = true`, which only ever
  held when a literal `content`/`prev_content` wrapper key was found —
  never for these wrapper-less write-path bodies.

  `in_content?: true` lets a ROUTE-AWARE caller (`RequestLogger`, for the
  send/state write-path routes specifically — see
  `request_logger.ex`'s `write_path_content_body?/1`) seed the SAME
  catch-all the read path already gets for free via its `content` wrapper.
  The default (`redact_payload/1`, or `in_content?: false`/omitted) is
  UNCHANGED and stays conservative, since not every top-level map handed to
  this module is itself a Matrix event `content` object (e.g. a `/sync`
  response envelope, or a login request body) — only wire this in for
  routes that are structurally known to send raw content at the top level.
  """
  @spec redact_payload(term(), keyword()) :: term()
  def redact_payload(nil, _opts), do: nil

  def redact_payload(payload, opts) when is_map(payload) do
    redact_map(payload, Keyword.get(opts, :in_content?, false))
  end

  def redact_payload(payload, opts) when is_list(payload) do
    in_content? = Keyword.get(opts, :in_content?, false)
    Enum.map(payload, &redact_value(&1, in_content?))
  end

  def redact_payload(payload, _opts) when is_binary(payload) do
    redact_string(payload)
  end

  def redact_payload(payload, _opts), do: payload

  # ── map/list walking ───────────────────────────────────────────────────────

  # `in_content?` tracks whether we are currently walking the direct children
  # of a Matrix event `content` object, so Category 2 redaction can apply its
  # "not metadata" rule to those (and only those) fields.
  #
  # `in_auth?` tracks whether we are currently walking the direct children of
  # a UIAA generic `auth` object, so its `token`/`session` fields (which are
  # credential-shaped only in that context) get redacted without over-
  # redacting unrelated `session`/`token`-named fields elsewhere.
  defp redact_map(map, in_content?, in_auth? \\ false) when is_map(map) do
    Map.new(map, fn {key, value} ->
      cond do
        credential_key?(key) or (in_auth? and uiaa_credential_key?(key)) ->
          {key, @redacted}

        # F2: `m.relates_to` is checked at ANY depth, BEFORE the in_content?
        # branch — it is never blanket-skipped as metadata. Its `key` child
        # (reaction emoji/text) is user-generated content; `rel_type`/
        # `event_id` are structural and survive.
        relates_to_key?(key) ->
          {key, redact_relates_to_value(value)}

        # F1: field-name-based content detection fires at ANY depth,
        # independent of whether we are currently "in_content?" (i.e. even
        # when there is no `content` wrapper at all, as on the Matrix write
        # path). Mirrors how credential_key?/1 already works above.
        always_content_key?(key) ->
          {key, redact_content_value(value)}

        in_content? and not content_metadata_key?(key) ->
          {key, redact_content_value(value)}

        true ->
          {key, redact_value(value, content_key?(key), auth_key?(key))}
      end
    end)
  end

  defp redact_value(value, in_content?, in_auth? \\ false)

  defp redact_value(value, in_content?, in_auth?) when is_map(value),
    do: redact_map(value, in_content?, in_auth?)

  defp redact_value(value, in_content?, in_auth?) when is_list(value) do
    Enum.map(value, &redact_value(&1, in_content?, in_auth?))
  end

  defp redact_value(value, _in_content?, _in_auth?) when is_binary(value),
    do: redact_string(value)

  defp redact_value(value, _in_content?, _in_auth?), do: value

  # A field that is itself the `content` object of a Matrix event: its
  # DIRECT children (msgtype/url/... aside) are message content, but nested
  # maps two levels down (e.g. `m.relates_to`) are handled by their own
  # metadata-key check rather than blanket "in content" propagation, to
  # avoid over-redacting structural sub-objects.
  #
  # `prev_content` (code-review cycle-2, m2): a Matrix state event's
  # `unsigned.prev_content` carries the PREVIOUS `content` object (e.g. the
  # room's previous name/topic before an edit) — same user-generated-content
  # shape and leak class as `content` itself (AC7), just reached via a
  # different key path.
  defp content_key?(key), do: normalize_key(key) in ~w(content prev_content)

  # A field that is itself the generic UIAA `auth` object of a Matrix
  # User-Interactive Auth request — its direct `token`/`session` children
  # are credential-shaped only in this context (AC4/AC5, Oracle spec).
  defp auth_key?(key), do: normalize_key(key) == "auth"

  # A leaf value that is itself content (either found directly inside a
  # `content`/`prev_content` object and not a recognised metadata key, or
  # matched by `always_content_key?/1` at any depth): mask it. A nested map
  # is fully masked (fail-closed — any structured sub-object under a
  # content-shaped key is itself user-generated, not structural metadata,
  # since `m.relates_to` — the one genuinely structural exception — is
  # handled separately by `relates_to_key?/1` before this function is ever
  # reached). A list recurses element-wise so each item is independently
  # masked.
  defp redact_content_value(value) when is_map(value), do: @message_content

  defp redact_content_value(value) when is_list(value),
    do: Enum.map(value, &redact_content_value/1)

  defp redact_content_value(_value), do: @message_content

  # `m.relates_to` (F2): carries structural metadata (`rel_type`, `event_id`)
  # plus, for some relation types, a user-generated `key` (e.g. reaction
  # emoji/text) — only `key` is message content. Always recursed into via
  # `redact_relation_map/1`, at ANY depth, never blanket-skipped as metadata
  # (the pre-fix bug: `m.relates_to` sat in the metadata allowlist, so the
  # walker recursed into it with `in_content?=false` and `key` was never
  # touched).
  defp relates_to_key?(key), do: normalize_key(key) == "m.relates_to"

  defp redact_relates_to_value(value) when is_map(value), do: redact_relation_map(value)
  defp redact_relates_to_value(value), do: redact_value(value, false)

  defp redact_relation_map(value) do
    Map.new(value, fn {k, v} ->
      if normalize_key(k) == "key" do
        {k, @message_content}
      else
        {k, redact_value(v, false)}
      end
    end)
  end

  defp always_content_key?(key), do: normalize_key(key) in @always_content_keys

  defp credential_key?(key) do
    normalized = normalize_key(key)
    normalized in @credential_keys or normalized == "authorization"
  end

  defp uiaa_credential_key?(key) do
    normalize_key(key) in ~w(token session)
  end

  defp content_metadata_key?(key) do
    normalize_key(key) in @content_metadata_keys
  end

  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key(key), do: key

  # ── string handling (headers, query strings, raw bodies) ────────────────────

  # Keys treated as credential-shaped when found in a raw (unstructured)
  # string, e.g. `key=value` query-string/form-encoded fragments or a
  # `"key": "value"` fragment inside a malformed/unparseable JSON-ish string
  # (code-review m5). `client_secret`/`id_access_token` added per security
  # review 2026-07-05, F4.
  @credential_string_keys ~w(
    password new_password access_token refresh_token token
    client_secret id_access_token
  )

  # Keys treated as message-content-shaped when found the same way. `body`
  # only — a narrow, deliberately conservative set, since (unlike credential
  # keys) a generic scan for content-shaped keys anywhere in arbitrary text
  # risks over-redacting unrelated data; `body` is the canonical AC6 example
  # and the one this LAW's "must never appear, even in malformed/edge-case
  # input" guarantee is most directly about.
  @content_string_keys ~w(body)

  # `key=value` style content: the media upload `?filename=` query param is
  # user-supplied (possibly personal) text.
  @content_query_keys ~w(filename)

  # Strings are treated as opaque — never `Jason.decode`d (see moduledoc):
  # that would risk fabricating structure from malformed input, or, for
  # binary media payloads, corrupting/misinterpreting raw bytes. As a
  # best-effort, defense-in-depth layer for strings this function cannot
  # (and must not) structurally parse — query strings, form-encoded bodies,
  # and malformed/unparseable JSON-ish fragments — a narrow set of
  # regex-based substitutions still scrub RECOGNIZABLE credential
  # (`key=value` AND `"key": "value"`) and message-content (`"key":
  # "value"` only) patterns. Each substitution is gated behind a cheap
  # `String.contains?/2` literal-substring pre-check, so this never risks a
  # `Regex.replace/3` scan of e.g. a raw binary media blob that does not
  # contain any of these substrings in the first place (matching the
  # existing, already-safe `access_token=` handling this replaces/extends).
  defp redact_string(value) do
    value
    |> redact_query_style(@content_query_keys, @message_content)
    |> redact_encoded_query_keys(@content_query_keys, @message_content)
    |> redact_query_style(@credential_string_keys, @redacted)
    |> redact_json_string_style(@credential_string_keys, @redacted)
    |> redact_json_string_style(@content_string_keys, @message_content)
  end

  # `key=value` style — query strings (`?access_token=...`) and
  # form-urlencoded bodies (e.g. an OAuth-style
  # `grant_type=refresh_token&refresh_token=...` refresh request).
  defp redact_query_style(value, keys, replacement) do
    Enum.reduce(keys, value, fn key, acc ->
      if String.contains?(acc, key <> "=") do
        Regex.replace(~r/#{Regex.escape(key)}=[^&\s"']*/, acc, key <> "=" <> replacement)
      else
        acc
      end
    end)
  end

  # Plug decodes percent-encoded parameter NAMES as well, so `?fil%65name=x`
  # is stored as `filename` but is invisible to the literal match above.
  # Decode each `name=value` pair's name and mask the value when it equals one
  # of `keys` (case-sensitive, exact: `x-filename` is NOT decoded to `filename`
  # and is left to the substring pass). Only runs when a `%` is present;
  # invalid percent-encoding in a name is tolerated (pair left unchanged).
  defp redact_encoded_query_keys(value, keys, replacement) do
    if String.contains?(value, "%") and String.contains?(value, "=") do
      Regex.replace(~r/([^&\s"'?=]+)=([^&\s"']*)/, value, fn whole, name, _val ->
        if name != "" and decoded_query_name(name) in keys do
          name <> "=" <> replacement
        else
          whole
        end
      end)
    else
      value
    end
  end

  defp decoded_query_name(name) do
    URI.decode_www_form(name)
  rescue
    ArgumentError -> nil
  end

  # `"key": "value"` style — a malformed/unparseable JSON-ish fragment that
  # still contains a recognisable quoted key. Only ever rewrites the exact
  # quoted key given, never a generic scan of arbitrary surrounding text.
  defp redact_json_string_style(value, keys, replacement) do
    Enum.reduce(keys, value, fn key, acc ->
      if String.contains?(acc, ~s("#{key}")) do
        Regex.replace(
          ~r/"#{Regex.escape(key)}"\s*:\s*"[^"]*"/,
          acc,
          ~s("#{key}": "#{replacement}")
        )
      else
        acc
      end
    end)
  end
end
