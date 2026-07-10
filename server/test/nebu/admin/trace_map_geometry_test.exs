defmodule Nebu.Admin.TraceMapGeometryTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/trace-map-leitstand`, AC2
  (radial SVG map layout and hierarchy — geometry half).

  Story: docs/stories/enhanced-logging/trace-map-leitstand.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md §2
  Visual reference (ground truth for every constant/formula below — the
  dummy's own `MODEL`/`R1`/`R2`/`rad()`/`edge()` functions):
  _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-dummy.html

  ## Why this MUST FAIL right now

  `Nebu.Admin.TraceMapGeometry` (server/lib/nebu/admin/trace_map_geometry.ex,
  per the story's own "Files to Create" list) does not exist yet. Every
  `Nebu.Admin.TraceMapGeometry.<fun>(...)` call below fails with
  `** (UndefinedFunctionError)`, NOT a compile error in this file (Elixir
  does not check a remote function exists at compile time).

  ## Module contract this file pins down (proposed — the dev agent may
  restructure the public API, e.g. return structs instead of plain maps, or
  fold these five functions into fewer/more, AS LONG AS the SVG rendered by
  `Nebu.Admin.LogsLive.TraceMap`'s `render/1` places every node at exactly
  the (x, y) this contract computes — see
  `trace_map_leitstand_test.exs`'s "AC2: radial SVG map" describe block for
  the rendered-output cross-check that keeps this file honest against the
  real template):

  Constants (spec §2, viewBox `-780 -650 1560 1300` — 2026-07-09
  domain-distance fix widened this from the original `-560 -400 1120 800`
  to keep pace with `@domain_ring` growing 220→300):

    * `@center_radius` 52 — nebu's own circle radius, always at `{0.0, 0.0}`.
    * `@domain_radius` 38 — every domain circle's radius.
    * `@satellite_radius` 24 — every satellite circle's radius.
    * `@domain_ring` 300.0 — R1, the ring domains sit on (measured from nebu).
    * `satellite_ring/1` — R2, the ring satellites sit on (measured from
      THEIR OWN domain's center, per the dummy's `edge()`/satellite-placement
      code — NOT from nebu). 2026-07-09 overlap fix: no longer a fixed
      constant — grows with the domain's own satellite count (base 150.0,
      +8.0 per satellite beyond 6) so a crowded domain's satellites never
      compress into overlapping circles.
    * `@edge_padding` 4 — trimmed off each end of an edge line, on top of the
      node's own radius.

  Functions:

    * `domain_angles(domain_keys :: [String.t()]) :: [{String.t(), float()}]`
      — one `{domain_key, angle_degrees}` pair per input key, SAME order as
      input (first-observed order, never re-sorted).

      Canonical rule (corrected by the 2026-07-09 domain-separation fix,
      identity-keyed via a plain map — NOT position-zipped): if EVERY key in
      `domain_keys` is one of the 4 known domains
      (`/_matrix/client`/`/_matrix/media`/`/admin`/`/health`), each gets its
      own fixed compass angle `0`/`-90`/`180`/`90` (east/north/west/south)
      REGARDLESS of how many of the 4 are present or what order they appear
      in — `/admin` and `/_matrix/client`, the two domains that realistically
      get crowded, always sit diametrically opposite (180° apart, the
      maximum possible separation) at the same height; `/health` is always
      due south, `/_matrix/media` always due north. (The original
      implementation only applied these angles on an EXACT 4-element,
      exact-order match, so a fresh/lightly-used instance with e.g. no
      `/_matrix/media` traffic yet — only 3 of the 4 domains rendered —
      silently regressed to generic even spacing; fixed because that is
      exactly the case an operator would be looking at.)

      Fallback rule (spec §2: "distribute evenly if domain count differs" —
      now covers ONLY a domain list containing at least one UNRECOGNIZED
      key, e.g. a 5th, truly novel domain): evenly distributed starting at
      `-90.0` degrees, stepping by `360.0 / length(domain_keys)` per domain,
      i.e. `angle(i) = -90.0 + i * (360.0 / n)` for `i` in `0..(n - 1)`.

    * `satellite_angles(domain_angle :: float(), count :: pos_integer()) ::
      [float()]` — `count` angles fanned around `domain_angle`, spread
      `min(320, count * 24)` degrees (2026-07-09 overlap fix, widened from
      the spec's original `min(130°, n·26°)` — see `satellite_ring/1`'s doc
      for why):

        * `count == 1` → `[domain_angle]` (centered exactly on the domain,
          no spread — dividing by `count - 1` would be a division by zero).
        * `count > 1` → `domain_angle - spread / 2 + i * (spread /
          (count - 1))` for `i` in `0..(count - 1)` (evenly fanned across
          the full spread, first satellite at `domain_angle - spread / 2`,
          last at `domain_angle + spread / 2`).

    * `polar_to_cartesian(angle_degrees :: float(), radius :: number()) ::
      {float(), float()}` — `{radius * :math.cos(radians), radius *
      :math.sin(radians)}`, standard SVG convention (positive Y is down,
      but this function does no Y-flip — same as the dummy's own `Math.cos`/
      `Math.sin` usage).

    * `trim_edge(a :: %{x: number(), y: number(), r: number()}, b :: %{x:
      number(), y: number(), r: number()}) :: {float(), float(), float(),
      float()}` — `{x1, y1, x2, y2}` for a straight line from `a` to `b`,
      shortened at EACH end by that end's own `r + @edge_padding` (spec §2
      "node edge + 4px"; mirrors the dummy's `edge()` function exactly).

    * `layout(domains :: [%{key: String.t(), satellites: [String.t()]}]) ::
      %{nebu: map(), domains: %{String.t() => map()}, satellites:
      %{String.t() => map()}}` — the full computed tree: `nebu` is always
      `%{x: 0.0, y: 0.0, r: 52}`; each domain map has `:x`/`:y`/`:r`/
      `:angle`; each satellite map has `:x`/`:y`/`:r`/`:angle`/`:domain`
      (its parent's key) — satellite absolute position is the PARENT
      DOMAIN's position plus the satellite's own polar offset (see
      `satellite_ring`'s doc above), not an offset from the origin.
  """

  use ExUnit.Case, async: true

  alias Nebu.Admin.TraceMapGeometry, as: Geometry

  @canonical_domains ["/_matrix/client", "/_matrix/media", "/admin", "/health"]

  # dev-story note: these wrappers used `apply/3` during the RED phase (the
  # module did not exist yet, and `mix test --warnings-as-errors`'s
  # xref-backed undefined-remote-function check would have turned the
  # intended runtime failures into compile errors). Now that
  # `Nebu.Admin.TraceMapGeometry` exists, they are DIRECT calls per the
  # test-review recommendation — xref checking is back on for this file.
  defp domain_angles(keys), do: Geometry.domain_angles(keys)
  defp satellite_angles(angle, count), do: Geometry.satellite_angles(angle, count)
  defp polar_to_cartesian(angle, radius), do: Geometry.polar_to_cartesian(angle, radius)
  defp trim_edge(a, b), do: Geometry.trim_edge(a, b)
  defp layout(domains), do: Geometry.layout(domains)

  # ══════════════════════════════════════════════════════════════════════
  # domain_angles/1
  # ══════════════════════════════════════════════════════════════════════

  describe "domain_angles/1 — canonical 4-domain fixed angles (2026-07-09 compass layout)" do
    test "the exact 4 named domains, in spec order, get the compass angles" do
      assert domain_angles(@canonical_domains) == [
               {"/_matrix/client", 0.0},
               {"/_matrix/media", -90.0},
               {"/admin", 180.0},
               {"/health", 90.0}
             ]
    end

    test "admin and matrix client sit diametrically opposite (180 degrees apart)" do
      [{_, client_angle}, _, {_, admin_angle}, _] = domain_angles(@canonical_domains)
      assert abs(admin_angle - client_angle) == 180.0
    end
  end

  describe "domain_angles/1 — even-distribution fallback" do
    test "1 domain sits at -90 degrees (the fallback's own start angle)" do
      assert domain_angles(["/only"]) == [{"/only", -90.0}]
    end

    test "2 domains are spaced 180 degrees apart, starting at -90" do
      assert domain_angles(["/a", "/b"]) == [{"/a", -90.0}, {"/b", 90.0}]
    end

    test "3 domains are spaced 120 degrees apart, starting at -90, in input order" do
      assert domain_angles(["/a", "/b", "/c"]) == [
               {"/a", -90.0},
               {"/b", 30.0},
               {"/c", 150.0}
             ]
    end

    test "an unrecognized domain key falls the WHOLE list back to even distribution, even alongside known ones" do
      out = domain_angles(["/admin", "/extra"])
      assert out == [{"/admin", -90.0}, {"/extra", 90.0}]
    end
  end

  describe "domain_angles/1 — 2026-07-09 fix: known domains get fixed angles regardless of order or completeness" do
    test "the canonical 4 domain KEYS in a DIFFERENT order still get their own fixed compass angles (identity, not position, decides the angle)" do
      out = domain_angles(["/admin", "/health", "/_matrix/client", "/_matrix/media"])

      assert out == [
               {"/admin", 180.0},
               {"/health", 90.0},
               {"/_matrix/client", 0.0},
               {"/_matrix/media", -90.0}
             ]
    end

    test "a SUBSET of the canonical domains (e.g. only 3 of 4 observed so far) still gets fixed compass angles, not a generic even fallback" do
      # The exact scenario that motivated this fix: a fresh/lightly-used
      # instance where /_matrix/media hasn't been hit yet, so only 3 of the
      # 4 known domains have rendered — Admin and Matrix Client must STILL
      # be 180° apart, not silently regressed to a 120°-apart even spacing.
      out = domain_angles(["/admin", "/_matrix/client", "/health"])

      assert out == [
               {"/admin", 180.0},
               {"/_matrix/client", 0.0},
               {"/health", 90.0}
             ]
    end

    test "just the 2 domains that realistically get crowded are still 180 degrees apart on their own" do
      assert domain_angles(["/_matrix/client", "/admin"]) ==
               [{"/_matrix/client", 0.0}, {"/admin", 180.0}]
    end

    test "5 domains (a superset of the canonical 4) also fall back to even distribution" do
      out = domain_angles(["/_matrix/client", "/_matrix/media", "/admin", "/health", "/extra"])
      assert length(out) == 5
      assert Enum.map(out, &elem(&1, 1)) == [-90.0, -18.0, 54.0, 126.0, 198.0]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # satellite_angles/2
  # ══════════════════════════════════════════════════════════════════════

  describe "satellite_angles/2 — fan spread (2026-07-09 overlap fix: min(320°, n·24°))" do
    test "a single satellite sits exactly on the domain's own angle (no spread)" do
      assert satellite_angles(-48.0, 1) == [-48.0]
    end

    test "3 satellites: spread = min(320, 72) = 72, evenly fanned" do
      assert satellite_angles(-48.0, 3) == [-84.0, -48.0, -12.0]
    end

    test "6 satellites: spread = min(320, 144) = 144 (no cap — 6*24=144 stays under 320)" do
      [a1, a2, a3, a4, a5, a6] = satellite_angles(-48.0, 6)

      assert_in_delta a1, -120.0, 0.001
      assert_in_delta a2, -91.2, 0.001
      assert_in_delta a3, -62.4, 0.001
      assert_in_delta a4, -33.6, 0.001
      assert_in_delta a5, -4.8, 0.001
      assert_in_delta a6, 24.0, 0.001
    end

    test "2 satellites: spread = min(320, 48) = 48, one at each edge of the spread" do
      assert satellite_angles(0.0, 2) == [-24.0, 24.0]
    end

    test "40 satellites: spread caps at 320, leaving a visible gap on the inward side" do
      angles = satellite_angles(-48.0, 40)
      assert length(angles) == 40
      assert_in_delta Enum.min(angles) - (-48.0), -160.0, 0.001
      assert_in_delta Enum.max(angles) - (-48.0), 160.0, 0.001
    end
  end

  describe "satellite_ring/1 — 2026-07-09 overlap fix: ring radius grows with satellite count" do
    test "up to the growth threshold (6), the ring stays at the 150.0 base" do
      assert Geometry.satellite_ring(1) == 150.0
      assert Geometry.satellite_ring(6) == 150.0
    end

    test "beyond 6 satellites, the ring grows 8.0 per extra satellite" do
      assert Geometry.satellite_ring(7) == 158.0
      assert Geometry.satellite_ring(10) == 182.0
    end

    test "a crowded domain (40 satellites) never packs tighter than a safe chord distance" do
      count = 40
      ring = Geometry.satellite_ring(count)
      [a1, a2 | _] = satellite_angles(0.0, count)
      step_radians = (a2 - a1) * :math.pi() / 180.0
      chord = 2 * ring * :math.sin(step_radians / 2)

      # two satellite circles (r=24 each) must not overlap: chord >= 48
      assert chord >= 48.0
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # polar_to_cartesian/2
  # ══════════════════════════════════════════════════════════════════════

  describe "polar_to_cartesian/2" do
    test "0 degrees points along +x" do
      {x, y} = polar_to_cartesian(0.0, 100.0)
      assert_in_delta x, 100.0, 0.0001
      assert_in_delta y, 0.0, 0.0001
    end

    test "90 degrees points along +y (SVG convention, no flip applied here)" do
      {x, y} = polar_to_cartesian(90.0, 100.0)
      assert_in_delta x, 0.0, 0.0001
      assert_in_delta y, 100.0, 0.0001
    end

    test "matches :math.cos/:math.sin directly for an arbitrary angle" do
      angle = -48.0
      radius = 195.0
      radians = angle * :math.pi() / 180.0

      {x, y} = polar_to_cartesian(angle, radius)

      assert_in_delta x, radius * :math.cos(radians), 0.0001
      assert_in_delta y, radius * :math.sin(radians), 0.0001
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # trim_edge/2
  # ══════════════════════════════════════════════════════════════════════

  describe "trim_edge/2 — edges trimmed by (radius + 4px) at each end" do
    test "a horizontal edge from nebu (r=52) to a domain (r=38) 100 units away" do
      nebu = %{x: 0.0, y: 0.0, r: 52}
      domain = %{x: 100.0, y: 0.0, r: 38}

      assert trim_edge(nebu, domain) == {56.0, 0.0, 58.0, 0.0}
    end

    test "trimming is symmetric under endpoint swap (start/end reverse, offsets stay own-radius-relative)" do
      a = %{x: 0.0, y: 0.0, r: 52}
      b = %{x: 100.0, y: 0.0, r: 38}

      {x1, y1, x2, y2} = trim_edge(a, b)
      {x2r, y2r, x1r, y1r} = trim_edge(b, a)

      assert_in_delta x1, x1r, 0.0001
      assert_in_delta y1, y1r, 0.0001
      assert_in_delta x2, x2r, 0.0001
      assert_in_delta y2, y2r, 0.0001
    end

    test "a diagonal edge trims along the correct unit vector" do
      a = %{x: 0.0, y: 0.0, r: 0}
      b = %{x: 30.0, y: 40.0, r: 0}

      # length 50, unit vector (0.6, 0.8); +4px padding at each end (r=0)
      assert {x1, y1, x2, y2} = trim_edge(a, b)
      assert_in_delta x1, 0.6 * 4, 0.0001
      assert_in_delta y1, 0.8 * 4, 0.0001
      assert_in_delta x2, 30.0 - 0.6 * 4, 0.0001
      assert_in_delta y2, 40.0 - 0.8 * 4, 0.0001
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # layout/1 — full tree
  # ══════════════════════════════════════════════════════════════════════

  describe "layout/1 — nebu is always fixed at the origin" do
    test "nebu is {0.0, 0.0} with radius 52 regardless of domain count" do
      layout = layout([%{key: "/only", satellites: ["/only/a"]}])
      assert layout.nebu == %{x: 0.0, y: 0.0, r: 52}
    end
  end

  describe "layout/1 — domains positioned on the R1=220 ring" do
    test "a single domain sits 220 units from the origin, at its own angle" do
      layout = layout([%{key: "/only", satellites: []}])
      domain = layout.domains["/only"]

      assert domain.r == 38
      assert domain.angle == -90.0
      assert_in_delta domain.x, 300.0 * :math.cos(-90.0 * :math.pi() / 180.0), 0.001
      assert_in_delta domain.y, 300.0 * :math.sin(-90.0 * :math.pi() / 180.0), 0.001
    end
  end

  describe "layout/1 — satellites positioned relative to their OWN domain, on the count-scaled satellite_ring/1" do
    test "a satellite's absolute position is its domain's position plus its own polar offset" do
      layout =
        layout([%{key: "/only", satellites: ["/only/a", "/only/b", "/only/c"]}])

      domain = layout.domains["/only"]
      sat_a = layout.satellites["/only/a"]

      assert sat_a.r == 24
      assert sat_a.domain == "/only"

      [expected_angle | _] = satellite_angles(domain.angle, 3)
      {dx, dy} = polar_to_cartesian(expected_angle, Geometry.satellite_ring(3))

      assert_in_delta sat_a.x, domain.x + dx, 0.001
      assert_in_delta sat_a.y, domain.y + dy, 0.001
      assert_in_delta sat_a.angle, expected_angle, 0.001
    end

    test "a crowded domain's satellites sit on a wider ring than a sparse domain's" do
      layout =
        layout([%{key: "/busy", satellites: Enum.map(1..12, &"/busy/route-#{&1}")}])

      domain = layout.domains["/busy"]
      sat = layout.satellites["/busy/route-1"]
      dist = :math.sqrt(:math.pow(sat.x - domain.x, 2) + :math.pow(sat.y - domain.y, 2))

      assert_in_delta dist, Geometry.satellite_ring(12), 0.001
      assert Geometry.satellite_ring(12) > Geometry.satellite_ring(3)
    end

    test "an empty satellites list produces no satellite entries for that domain (no crash)" do
      layout = layout([%{key: "/empty", satellites: []}])
      assert layout.domains["/empty"]
      refute Map.has_key?(layout.satellites, "/empty/anything")
    end
  end

  describe "layout/1 — the canonical 4-domain shape end-to-end" do
    test "all 4 domains and their satellites are present, keyed by their own strings" do
      domains = [
        %{key: "/_matrix/client", satellites: ["/_matrix/client/v3/sync", "/_matrix/client/v3/login"]},
        %{key: "/_matrix/media", satellites: ["/_matrix/media/v3/upload"]},
        %{key: "/admin", satellites: ["/admin/users"]},
        %{key: "/health", satellites: ["/health"]}
      ]

      layout = layout(domains)

      assert Map.keys(layout.domains) |> Enum.sort() ==
               Enum.sort(@canonical_domains)

      assert layout.domains["/_matrix/client"].angle == 0.0
      assert layout.domains["/health"].angle == 90.0

      assert layout.satellites["/_matrix/client/v3/sync"].domain == "/_matrix/client"
      assert layout.satellites["/health"].domain == "/health"
    end
  end
end
