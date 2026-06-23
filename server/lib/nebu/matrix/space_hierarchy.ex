defmodule Nebu.Matrix.SpaceHierarchy do
  @moduledoc """
  Spaces S3 — MSC2946 space hierarchy traversal.

  `get_hierarchy/3` does a breadth-first walk over `m.space.child` state events,
  starting from a root Space, and returns the flattened, BFS-ordered list of
  *visible* room summaries plus an opaque pagination cursor.

  ## Design

    * **BFS, cycle-safe.** A `visited` MapSet of room ids guarantees each room is
      visited at most once even when the `m.space.child` graph is cyclic. The
      BFS frontier is processed level-by-level so `max_depth` is a clean cutoff
      (`0` = root only, `1` = root + direct children, …).

    * **Visibility filter (security boundary).** Each candidate room is resolved
      through `room_summary/2`. A room the requesting user may NOT see (private &
      non-member, not world-readable) resolves to `:hidden`: it is EXCLUDED from
      the output, but — per spec — its `m.space.child` edges are STILL traversed
      so the rest of the tree is reachable. The summary is built by the caller
      (the server wrapper / DB helper), so this module never reads private state
      itself; it only sees what the resolver chose to expose.

    * **Deterministic ordering + pagination.** The full visible BFS list is a
      stable, deterministic sequence (level order, edge order preserved). A page
      is the window `[offset, offset + limit)` of that sequence. `next_batch` is
      an opaque Base64 token encoding the next offset; an empty/invalid window
      yields no `next_batch`. A forged/malformed token fails closed
      (`{:error, :invalid_token}`) — it never silently resets to page 0.

  ## Injectable lookups (Repo-less testing)

  `opts` carries two function injections so the BFS can be unit-tested without a
  live DB or Horde:

    * `:child_lookup` — `(room_id) -> [{child_room_id, child_content_map}]`
    * `:room_summary` — `(room_id, user_id) -> {:ok, summary_map} | :hidden`

  In production the server wrapper supplies DB-backed implementations.

  A `summary_map` has the keys: `:room_id, :name, :topic, :canonical_alias,
  :num_joined_members, :world_readable, :guest_can_join, :join_rule, :room_type,
  :avatar_url, :children_state`.
  """

  @max_limit 1000

  @type summary :: %{
          room_id: String.t(),
          name: String.t(),
          topic: String.t(),
          canonical_alias: String.t(),
          num_joined_members: non_neg_integer(),
          world_readable: boolean(),
          guest_can_join: boolean(),
          join_rule: String.t(),
          room_type: String.t() | nil,
          avatar_url: String.t(),
          children_state: [map()]
        }

  @doc """
  Breadth-first traversal from `root_room_id` for `user_id`.

  Returns `{rooms, next_batch}` on success (a possibly-empty list of summary maps
  and an opaque token, "" when there are no further pages), or
  `{:error, :invalid_token}` when `opts[:from_token]` is forged/malformed.

  Options:
    * `:limit` — page size (clamped to `1..1000`; default 100)
    * `:max_depth` — BFS depth cap (`>= 0`; default 10)
    * `:suggested_only` — only follow/include `m.space.child` with
      `content["suggested"] == true` (default false; the root is always included)
    * `:from_token` — opaque pagination cursor ("" = first page)
    * `:child_lookup` / `:room_summary` — injectable lookups (see moduledoc)
  """
  @spec get_hierarchy(String.t(), String.t(), keyword()) ::
          {[summary()], String.t()} | {:error, :invalid_token}
  def get_hierarchy(root_room_id, user_id, opts) do
    limit = opts |> Keyword.get(:limit, 100) |> clamp_limit()
    max_depth = opts |> Keyword.get(:max_depth, 10) |> max(0)
    suggested_only = Keyword.get(opts, :suggested_only, false)
    child_lookup = Keyword.fetch!(opts, :child_lookup)
    room_summary = Keyword.fetch!(opts, :room_summary)
    from_token = Keyword.get(opts, :from_token, "") || ""

    with {:ok, offset} <- parse_offset(from_token) do
      # The full deterministic visible BFS sequence. Pagination is a window over it.
      all =
        bfs(root_room_id, user_id, max_depth, suggested_only, child_lookup, room_summary)

      page = all |> Enum.drop(offset) |> Enum.take(limit)
      next_offset = offset + length(page)

      next_batch =
        if next_offset < length(all), do: encode_token(next_offset), else: ""

      {page, next_batch}
    end
  end

  # ── BFS core ────────────────────────────────────────────────────────────────
  #
  # Returns the ordered list of VISIBLE summary maps. Hidden rooms are dropped
  # from the output but their children are still enqueued (spec requirement).

  defp bfs(root_room_id, user_id, max_depth, suggested_only, child_lookup, room_summary) do
    # frontier = [{room_id, depth}]; visited guards against cycles + diamonds.
    do_bfs([{root_room_id, 0}], MapSet.new(), [], user_id, max_depth, suggested_only,
      child_lookup, room_summary)
  end

  defp do_bfs([], _visited, acc, _user_id, _max_depth, _suggested, _child_lookup, _room_summary) do
    Enum.reverse(acc)
  end

  defp do_bfs([{room_id, depth} | rest], visited, acc, user_id, max_depth, suggested_only,
         child_lookup, room_summary) do
    if MapSet.member?(visited, room_id) do
      do_bfs(rest, visited, acc, user_id, max_depth, suggested_only, child_lookup, room_summary)
    else
      visited = MapSet.put(visited, room_id)

      # Resolve visibility. A hidden room contributes nothing to the output but
      # its children are still traversed (so the subtree stays reachable).
      acc =
        case room_summary.(room_id, user_id) do
          {:ok, summary} -> [summary | acc]
          :hidden -> acc
        end

      # Enqueue children unless we are at the depth cap. Edge order is preserved
      # (deterministic). suggested_only prunes both inclusion AND traversal of
      # non-suggested edges (a non-suggested sub-space subtree is not entered).
      next_frontier =
        if depth >= max_depth do
          []
        else
          room_id
          |> child_lookup.()
          |> Enum.filter(fn {_child, content} ->
            not suggested_only or suggested?(content)
          end)
          |> Enum.map(fn {child_id, _content} -> {child_id, depth + 1} end)
        end

      do_bfs(rest ++ next_frontier, visited, acc, user_id, max_depth, suggested_only,
        child_lookup, room_summary)
    end
  end

  defp suggested?(content) when is_map(content), do: content["suggested"] == true
  defp suggested?(_), do: false

  # ── limit clamp ───────────────────────────────────────────────────────────

  @doc "Clamps a requested page size into `1..#{@max_limit}`."
  @spec clamp_limit(integer()) :: pos_integer()
  def clamp_limit(n) when is_integer(n) and n < 1, do: 1
  def clamp_limit(n) when is_integer(n) and n > @max_limit, do: @max_limit
  def clamp_limit(n) when is_integer(n), do: n
  def clamp_limit(_), do: 100

  @doc "The server-side maximum page size (spec clamp)."
  def max_limit, do: @max_limit

  # ── Opaque pagination token ─────────────────────────────────────────────────
  #
  # The cursor is just the BFS offset, wrapped so a client cannot read or forge
  # internal state meaningfully. Format: url-safe Base64 of "h1:<offset>".
  # Decoding rejects anything that is not exactly that shape — fail closed.

  @token_prefix "h1:"

  @doc "Encodes a non-negative BFS offset into an opaque url-safe Base64 cursor."
  @spec encode_token(non_neg_integer()) :: String.t()
  def encode_token(offset) when is_integer(offset) and offset >= 0 do
    Base.url_encode64(@token_prefix <> Integer.to_string(offset), padding: false)
  end

  @doc """
  Decodes an opaque cursor back to its offset.

  Returns `{:ok, offset}` or `{:error, :invalid_token}` for anything that is not
  a well-formed token (forged, truncated, non-numeric, negative).
  """
  @spec decode_token(String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_token}
  def decode_token(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         @token_prefix <> rest <- decoded,
         {offset, ""} <- Integer.parse(rest),
         true <- offset >= 0 do
      {:ok, offset}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def decode_token(_), do: {:error, :invalid_token}

  # "" (no token) means the first page (offset 0). Any other value must decode.
  defp parse_offset(""), do: {:ok, 0}
  defp parse_offset(token), do: decode_token(token)
end
