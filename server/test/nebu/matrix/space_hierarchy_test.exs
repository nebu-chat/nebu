defmodule Nebu.Matrix.SpaceHierarchyTest do
  use ExUnit.Case, async: true

  # ─── Spaces S3 — SpaceHierarchy BFS (get_hierarchy/3) ─────────────────────────
  #
  # Story: spaces-elixir / s3-space-hierarchy (MSC2946).
  #
  # Repo-less unit tests: get_hierarchy/3 is driven with INJECTED lookup functions
  # (opts[:child_lookup] + opts[:room_summary]) so no PostgreSQL / Horde is needed.
  # The injected child_lookup returns the m.space.child edges of a room; room_summary
  # returns the room's summary map (or :hidden when the user may not see it).
  #
  # Covers Acceptance Tests 1-4:
  #   1. full-depth BFS (6 rooms, BFS order, room_type carried)
  #   2. max_depth: 1 / 0
  #   3. suggested_only: true filters
  #   4. visibility: a hidden room is excluded BUT its children are still traversed
  #   + pagination token round-trip and forged-token fail-closed.

  alias Nebu.Matrix.SpaceHierarchy

  # ── Fixture graph ─────────────────────────────────────────────────────────
  #
  #   !root  (m.space)
  #     ├─ !a   (regular child)
  #     ├─ !b   (regular child)
  #     └─ !sub (m.space, sub-space)
  #          ├─ !c
  #          └─ !d
  #
  # BFS order from !root: root, a, b, sub, c, d  (level order, edge order preserved).

  @edges %{
    "!root" => [
      {"!a", %{"suggested" => true}},
      {"!b", %{"suggested" => false}},
      {"!sub", %{}}
    ],
    "!sub" => [
      {"!c", %{"suggested" => true}},
      {"!d", %{}}
    ]
  }

  @types %{"!root" => "m.space", "!sub" => "m.space"}

  # child_lookup(room_id) → [{child_room_id, child_content_map}]
  defp child_lookup do
    fn room_id -> Map.get(@edges, room_id, []) end
  end

  # room_summary(room_id, user_id) → {:ok, summary_map} | :hidden
  # Every room visible by default; a per-test hidden set overrides it.
  defp room_summary(hidden \\ MapSet.new()) do
    fn room_id, _user_id ->
      if MapSet.member?(hidden, room_id) do
        :hidden
      else
        {:ok,
         %{
           room_id: room_id,
           name: "name-#{room_id}",
           topic: "",
           canonical_alias: "",
           num_joined_members: 1,
           world_readable: false,
           guest_can_join: false,
           join_rule: "invite",
           room_type: Map.get(@types, room_id),
           avatar_url: "",
           children_state: []
         }}
      end
    end
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        limit: 100,
        max_depth: 10,
        suggested_only: false,
        from_token: "",
        child_lookup: child_lookup(),
        room_summary: room_summary()
      ],
      extra
    )
  end

  defp ids(rooms), do: Enum.map(rooms, & &1.room_id)

  # ── AT1 — full-depth BFS ───────────────────────────────────────────────────

  test "AT1: full-depth BFS returns all 6 rooms in BFS order with room_type set" do
    {rooms, next} = SpaceHierarchy.get_hierarchy("!root", "@u:x", opts())

    assert ids(rooms) == ["!root", "!a", "!b", "!sub", "!c", "!d"]
    assert next == ""

    by_id = Map.new(rooms, &{&1.room_id, &1})
    assert by_id["!root"].room_type == "m.space"
    assert by_id["!sub"].room_type == "m.space"
    assert by_id["!a"].room_type == nil
  end

  # ── AT2 — max_depth ────────────────────────────────────────────────────────

  test "AT2: max_depth 1 returns only the root + its direct children (no grandchildren)" do
    {rooms, _next} = SpaceHierarchy.get_hierarchy("!root", "@u:x", opts(max_depth: 1))

    assert ids(rooms) == ["!root", "!a", "!b", "!sub"]
    refute "!c" in ids(rooms)
    refute "!d" in ids(rooms)
  end

  test "AT2: max_depth 0 returns just the root" do
    {rooms, _next} = SpaceHierarchy.get_hierarchy("!root", "@u:x", opts(max_depth: 0))
    assert ids(rooms) == ["!root"]
  end

  # ── AT3 — suggested_only ───────────────────────────────────────────────────

  test "AT3: suggested_only keeps the root + only children flagged suggested=true" do
    {rooms, _next} = SpaceHierarchy.get_hierarchy("!root", "@u:x", opts(suggested_only: true))

    # root always included; among children only !a (suggested) and !c (suggested under !sub).
    # !sub is NOT suggested, so its subtree is not entered → !c excluded too.
    assert ids(rooms) == ["!root", "!a"]
  end

  # ── AT4 — visibility ───────────────────────────────────────────────────────

  test "AT4: a hidden room is excluded from output but its children are still traversed" do
    # Hide !sub: it must not appear, but !c and !d (its children) still must.
    o = opts(room_summary: room_summary(MapSet.new(["!sub"])))
    {rooms, _next} = SpaceHierarchy.get_hierarchy("!root", "@u:x", o)

    refute "!sub" in ids(rooms)
    assert "!c" in ids(rooms)
    assert "!d" in ids(rooms)
    assert ids(rooms) == ["!root", "!a", "!b", "!c", "!d"]
  end

  # ── Pagination ─────────────────────────────────────────────────────────────

  test "pagination: limit splits the BFS into stable pages via next_batch round-trip" do
    {p1, next1} = SpaceHierarchy.get_hierarchy("!root", "@u:x", opts(limit: 2))
    assert ids(p1) == ["!root", "!a"]
    assert next1 != ""

    {p2, next2} = SpaceHierarchy.get_hierarchy("!root", "@u:x", opts(limit: 2, from_token: next1))
    assert ids(p2) == ["!b", "!sub"]
    assert next2 != ""

    {p3, next3} = SpaceHierarchy.get_hierarchy("!root", "@u:x", opts(limit: 2, from_token: next2))
    assert ids(p3) == ["!c", "!d"]
    assert next3 == ""
  end

  test "pagination: a forged / malformed from_token fails closed" do
    assert {:error, :invalid_token} =
             SpaceHierarchy.get_hierarchy("!root", "@u:x", opts(from_token: "not-a-real-token!!"))
  end

  test "pagination: a valid token round-trips through encode/decode" do
    token = SpaceHierarchy.encode_token(4)
    assert {:ok, 4} = SpaceHierarchy.decode_token(token)
    assert {:error, :invalid_token} = SpaceHierarchy.decode_token("@@@notbase64@@@")
  end

  # ── cycle safety ───────────────────────────────────────────────────────────

  test "BFS is cycle-safe (a child pointing back to the root does not loop)" do
    cyclic =
      fn
        "!root" -> [{"!a", %{}}]
        "!a" -> [{"!root", %{}}]
        _ -> []
      end

    {rooms, _next} =
      SpaceHierarchy.get_hierarchy("!root", "@u:x", opts(child_lookup: cyclic))

    # root + a, each visited once.
    assert ids(rooms) == ["!root", "!a"]
  end
end
