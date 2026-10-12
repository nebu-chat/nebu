defmodule Nebu.Web.LogStore.RouteNormalizer do
  @moduledoc """
  Pure, side-effect-free normalization of an HTTP request path into a
  `route_template` suitable for endpoint-level aggregation in the operational
  log store (enhanced-logging/operational-log-store, AC5).

  ## Design

  `server/lib/nebu/web/router/protected.ex` uses a plain `Plug.Router` with
  literal path macros — there is no automatic route-template metadata like
  `Phoenix.Router` provides. This module is a pragmatic, NOT-a-router-rewrite
  approximation: it replaces known Matrix ID-sigil-shaped path segments with a
  placeholder, good enough for grouping (not claimed to be 100% precise).

  ## The `state_key` rule (Oracle gate — LAW area)

  `PUT /rooms/{roomId}/state/{eventType}/{stateKey}` — `state_key` is a path
  SEGMENT that may contain ARBITRARY/SENSITIVE content: plain text, an empty
  string, or punctuation/whitespace — NOT necessarily an opaque, ID-shaped
  token. A naive "does this look like an opaque ID" regex (e.g.
  `[a-f0-9\\-]{32,}`) would fail to match a non-UUID-shaped `state_key` and
  leak it verbatim. Instead, the `state_key` segment is identified STRUCTURALLY
  (by its POSITION — two segments after a literal `"state"` segment) and
  replaced UNCONDITIONALLY, regardless of its content.

  ## Position-based rules for non-sigil segments (code-review M2)

  Several Matrix CS API path segments carry no leading sigil AND are
  realistically NOT hex/UUID-shaped (so the generic `@opaque_id_regex`
  fallback below essentially never matches them in practice) — a client's
  `txn_id` is typically a short, client-chosen opaque string (e.g.
  `m1234567890`), and `device_id` values are similarly short and non-hex.
  These are identified the SAME way `state_key` is — by POSITION relative to
  a known literal path segment — not by shape:

    * `/rooms/{roomId}/send/{eventType}/{txnId}` — `eventType` (1 after
      `"send"`) and `txnId` (2 after `"send"`)
    * `/rooms/{roomId}/state/{eventType}/{stateKey}` — `eventType` (1 after
      `"state"`, in addition to the pre-existing `stateKey` rule)
    * `/rooms/{roomId}/redact/{eventId}/{txnId}` — `txnId` (2 after
      `"redact"`; `eventId` already carries a `$` sigil and is matched
      generically)
    * `/devices/{deviceId}` — `deviceId` (1 after `"devices"`)
    * `.../account_data/{type}` (both `/user/{userId}/account_data/{type}`
      and `/user/{userId}/rooms/{roomId}/account_data/{type}`) — `type` (1
      after `"account_data"`)
    * `.../rooms/{roomId}/tags/{tag}` — the room-tag name (1 after `"tags"`):
      user-chosen content (`u.<anything>`), so it must not reach the request log

  `eventType` values (e.g. `m.room.message`) are not secret/sensitive, but
  are replaced anyway for consistent endpoint-level grouping — matching the
  story's own schema example (`"/rooms/:room_id/send/:event_type/:txn_id"`).

  ## Sigil-based segment identification

  Room IDs (`!`), user IDs (`@`), room aliases (`#`), and event IDs (`$`) are
  identified by their leading sigil character (Matrix spec) after
  percent-decoding the segment — so both a raw `!room:localhost` segment and a
  percent-encoded `%21room%3Alocalhost` variant are recognised, regardless of
  whether the given `path` has already been percent-decoded upstream (Plug
  typically already decodes `conn.request_path`, but this function does not
  assume that). Localparts MAY contain arbitrary Unicode (except `:`/NUL) per
  the Matrix spec's historical/federation identity allowance — sigil detection
  is byte/codepoint-agnostic (it only inspects the FIRST character), so it
  does not depend on an ASCII-only character class.
  """

  @room_id_placeholder ":room_id"
  @user_id_placeholder ":user_id"
  @room_alias_placeholder ":room_alias"
  @event_id_placeholder ":event_id"
  @state_key_placeholder ":state_key"
  @event_type_placeholder ":event_type"
  @txn_id_placeholder ":txn_id"
  @device_id_placeholder ":device_id"
  @account_data_type_placeholder ":type"
  @tag_placeholder ":tag"
  @opaque_id_placeholder ":id"

  # anchor literal segment => %{offset => placeholder}. `offset` is counted
  # in path segments AFTER the anchor (1 = immediately following it). See
  # the "Position-based rules for non-sigil segments" moduledoc section.
  @anchor_rules %{
    "send" => %{1 => @event_type_placeholder, 2 => @txn_id_placeholder},
    "state" => %{1 => @event_type_placeholder, 2 => @state_key_placeholder},
    "redact" => %{2 => @txn_id_placeholder},
    "devices" => %{1 => @device_id_placeholder},
    "account_data" => %{1 => @account_data_type_placeholder},
    "tags" => %{1 => @tag_placeholder}
  }

  # A conservative, ADDITIONAL heuristic for opaque hex/UUID-shaped segments
  # that carry no Matrix sigil (e.g. txn IDs, media IDs). Deliberately NOT
  # relied upon for state_key/alias/user/room handling above — those are
  # matched structurally or by sigil, never by "does this look ID-shaped".
  @opaque_id_regex ~r/^[0-9a-fA-F]{32,}$/

  @doc """
  Normalizes `path` (a `conn.request_path`-shaped string) into a
  `route_template` with sensitive path segments replaced by placeholders.

  Pure — no side effects, deterministic (same input always yields the same
  output), and safe on `nil`/empty input (returns the input unchanged rather
  than raising).
  """
  @spec normalize_route(String.t() | nil) :: String.t() | nil
  def normalize_route(nil), do: nil
  def normalize_route(""), do: ""

  def normalize_route(path) when is_binary(path) do
    segments = String.split(path, "/")
    special = special_index_map(segments)

    segments
    |> Enum.with_index()
    |> Enum.map(fn {segment, idx} ->
      case Map.fetch(special, idx) do
        {:ok, placeholder} -> placeholder
        :error -> normalize_segment(segment)
      end
    end)
    |> Enum.join("/")
  end

  # Builds a `%{raw_segment_index => placeholder}` map for every `@anchor_rules`
  # entry whose literal anchor segment (e.g. `"state"`, `"send"`, `"tags"`) is
  # present. Structural, position-based detection — each matched segment is
  # replaced UNCONDITIONALLY, regardless of shape/content (Oracle gate; same
  # rule already applied to `state_key`, generalized to `event_type`/`txn_id`/
  # `device_id`/account-data `type`/room `tag`, none of which carry a Matrix
  # sigil — code-review M2).
  #
  # Router-identical segmentation (room-tags review): `Plug.Router` matches on
  # `path_info`, i.e. it DROPS empty segments (`a//b` == `a/b`) and
  # percent-decodes each segment (`%74ags` == `tags`). The anchor and offsets
  # are therefore computed on that same view (empty segments removed, each
  # segment decoded with the never-raising `safe_decode/1`), so a path the
  # router accepts cannot dodge a placeholder via `//` or percent-encoding.
  # The returned indices refer back to the RAW split list, so the output keeps
  # the input's structure (empty segments / trailing slash are preserved; only
  # the matched segments are replaced). EVERY occurrence of an anchor applies
  # (over-redaction of a literal anchor-named segment is harmless).
  defp special_index_map(segments) do
    # [{raw_index, decoded_segment}] of the non-empty segments, in order.
    routed =
      segments
      |> Enum.with_index()
      |> Enum.reject(fn {segment, _idx} -> segment == "" end)
      |> Enum.map(fn {segment, idx} -> {idx, safe_decode(segment)} end)

    # Trailing empty raw segments (trailing slash) directly after the last
    # routed segment still count as target slots: `PUT .../state/m.room.topic/`
    # is the legal EMPTY-state_key request and must keep yielding
    # `.../state/:event_type/:state_key` (not a second route_template variant
    # for the same endpoint). They are targets only, never anchors.
    last_raw_idx = routed |> List.last({-1, nil}) |> elem(0)
    trailing_raw = Enum.to_list((last_raw_idx + 1)..(length(segments) - 1)//1)

    raw_by_pos =
      (Enum.map(routed, &elem(&1, 0)) ++ trailing_raw) |> List.to_tuple()

    slot_count = tuple_size(raw_by_pos)

    routed
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{_raw_idx, decoded}, pos}, acc ->
      case Map.fetch(@anchor_rules, decoded) do
        :error ->
          acc

        {:ok, offsets} ->
          Enum.reduce(offsets, acc, fn {offset, placeholder}, acc2 ->
            target = pos + offset

            if target < slot_count do
              Map.put(acc2, elem(raw_by_pos, target), placeholder)
            else
              acc2
            end
          end)
      end
    end)
  end

  defp normalize_segment(""), do: ""

  defp normalize_segment(segment) do
    decoded = safe_decode(segment)

    cond do
      String.starts_with?(decoded, "!") -> @room_id_placeholder
      String.starts_with?(decoded, "@") -> @user_id_placeholder
      String.starts_with?(decoded, "#") -> @room_alias_placeholder
      String.starts_with?(decoded, "$") -> @event_id_placeholder
      Regex.match?(@opaque_id_regex, decoded) -> @opaque_id_placeholder
      true -> segment
    end
  end

  # Percent-decoding is best-effort: a segment that happens to contain a "%"
  # not followed by a valid two-digit hex escape must never crash
  # normalization (this runs on the hot request path) — fall back to the
  # segment as-is so sigil detection still has a chance on the raw text.
  defp safe_decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end
end
