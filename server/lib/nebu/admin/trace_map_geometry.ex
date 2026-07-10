defmodule Nebu.Admin.TraceMapGeometry do
  @moduledoc """
  Pure geometry for the Trace Map "Leitstand" radial SVG map
  (enhanced-logging/trace-map-leitstand, AC2).

  Story: docs/stories/enhanced-logging/trace-map-leitstand.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md §2
  (the interactive dummy `trace-map-leitstand-dummy.html`'s own `MODEL`/`R1`/
  `R2`/`rad()`/`edge()` code is the numeric ground truth this module mirrors).

  A plain Elixir module — NO LiveView/HTML knowledge (spec §8 constraint 3,
  ADR-018/019/021): `Nebu.Admin.LogsLive.TraceMap.render/1` renders the SVG
  server-side in HEEx from the `{x, y}` positions computed here; LiveView
  patches only ever update node classes/counters, never positions.

  All constants use the SVG viewBox `-780 -650 1560 1300` coordinate space
  (widened 2026-07-09 from the spec's original `-560 -400 1120 800` to keep
  pace with `@domain_ring` growing 220→300 — see that constant's own doc):

    * nebu (center) circle r=52, always at the origin `{0.0, 0.0}`
    * domain circles r=38 on the R1=300 ring around nebu
    * satellite circles r=24 fanned over `min(320°, n·24°)` centered on the
      domain's outward angle, on a ring around THEIR OWN domain (not
      around nebu) that GROWS with the satellite count (`satellite_ring/1`)
      so a crowded domain never packs its satellites tighter than a safe
      non-overlapping chord distance — see that function's doc for the
      2026-07-09 overlap fix (a domain with dozens of distinct observed
      route templates, e.g. `/_matrix/client` on a busy homeserver, must
      still render as non-overlapping circles, not just the few
      hand-picked examples the design dummy showed)
    * edges are straight lines trimmed by (node radius + 4px) at each end
  """

  @center_radius 52
  @domain_radius 38
  @satellite_radius 24
  # 220 -> 300 (2026-07-09, same day as the compass-layout fix above): the
  # design owner wanted domains — Admin and Matrix Client especially —
  # pushed noticeably further from nebu, for more visual breathing room
  # between the center and each domain's own (now count-scaled, up to ~450
  # wide for a crowded domain) satellite fan.
  @domain_ring 300.0
  @satellite_ring_base 150.0
  @satellite_ring_growth_per_extra 8.0
  @satellite_ring_growth_threshold 6
  @edge_padding 4

  # 2026-07-09 domain-separation fix: a "compass" layout (N/E/S/W, each 90°
  # apart) for the 4 named domains this app actually knows about. Replaces
  # the spec's original hand-placed [-48, 48, 132, -132] (domains only
  # ~84-96° apart), which — combined with the same day's satellite-overlap
  # fix widening each domain's own fan to up to 320° — let two BUSY
  # neighboring domains' satellite fans visually collide with each other
  # (reported live: "bei admin und matrix wenn viel passiert, überlagern die
  # sich"). `/admin` and `/_matrix/client` are the two domains that
  # realistically get crowded, so they are placed diametrically OPPOSITE
  # (180° apart — the maximum possible separation for two points), at the
  # same height, left and right of nebu. `/health` sits due south (rarely
  # crowded — a single leaf endpoint); `/_matrix/media` due north (its own
  # opposite, for the same even-spacing reason, and it's also low-traffic
  # relative to `/_matrix/client`).
  #
  # Keyed by IDENTITY, not position (a plain map, not a zip): a domain's
  # angle must never depend on which OTHER domains happen to also be
  # present, or on first-observed order — the original `Enum.zip/2`-based
  # implementation only applied these angles when the input was the exact
  # 4-key list in the exact spec order, so on a fresh/lightly-used instance
  # (e.g. no `/_matrix/media` traffic observed yet, only 3 of the 4 domains
  # rendered), Admin and Matrix Client silently fell back to generic
  # 120°-apart even spacing — defeating the whole point of this fix on the
  # exact "not enough traffic to have seen every domain yet" case where an
  # operator would actually be looking at the map. Any INPUT KEY not in this
  # map (an unrecognized domain) falls the WHOLE list back to even
  # distribution below, since a fixed angle can't be assigned to it.
  @canonical_angles %{
    "/_matrix/client" => 0.0,
    "/_matrix/media" => -90.0,
    "/admin" => 180.0,
    "/health" => 90.0
  }

  @doc """
  One `{domain_key, angle_degrees}` pair per input key, in input order
  (first-observed order, never re-sorted).

  Any of the 4 known domains (`/_matrix/client`, `/_matrix/media`, `/admin`,
  `/health`) present in `keys` — in ANY subset, ANY order — gets its own
  fixed compass angle (`0`/`-90`/`180`/`90`, i.e. east/north/west/south —
  2026-07-09 domain-separation fix). If `keys` contains even one
  unrecognized domain, the WHOLE list falls back to even distribution
  starting at -90°, stepping `360 / n`.
  """
  @spec domain_angles([String.t()]) :: [{String.t(), float()}]
  def domain_angles([]), do: []

  def domain_angles(keys) when is_list(keys) do
    if Enum.all?(keys, &Map.has_key?(@canonical_angles, &1)) do
      Enum.map(keys, &{&1, Map.fetch!(@canonical_angles, &1)})
    else
      step = 360.0 / length(keys)

      keys
      |> Enum.with_index()
      |> Enum.map(fn {key, i} -> {key, -90.0 + i * step} end)
    end
  end

  @doc """
  `count` satellite angles fanned around `domain_angle`, spread over
  `min(320°, count·24°)` (2026-07-09 overlap fix — widened from the spec's
  original `min(130°, count·26°)`, which compressed satellites well below
  a safe non-overlapping angular step once a domain had more than ~7
  satellites; see `satellite_ring/1` for the matching ring-radius half of
  this fix). A single satellite sits exactly on the domain's own angle (no
  spread). The 320° ceiling (not a full 360°) deliberately leaves a visible
  gap on the inward side even for very crowded domains, so the fan never
  visually closes into a full ring.
  """
  @spec satellite_angles(float(), pos_integer()) :: [float()]
  def satellite_angles(domain_angle, 1), do: [domain_angle]

  def satellite_angles(domain_angle, count) when is_integer(count) and count > 1 do
    spread = min(320.0, count * 24.0)
    step = spread / (count - 1)

    for i <- 0..(count - 1), do: domain_angle - spread / 2 + i * step
  end

  @doc """
  The satellite ring radius (R2) for a domain with `count` satellites
  (2026-07-09 overlap fix). Grows past the base 150px once a domain has
  more than #{@satellite_ring_growth_threshold} satellites, so the
  increasing circumference keeps pace with `satellite_angles/2`'s
  increasingly-tight angular step — a domain with dozens of distinct
  observed endpoints (a busy `/_matrix/client`, say) still renders its
  satellites as touching-at-most, never overlapping, circles.
  """
  @spec satellite_ring(non_neg_integer()) :: float()
  def satellite_ring(count) when is_integer(count) and count >= 0 do
    @satellite_ring_base +
      max(0, count - @satellite_ring_growth_threshold) * @satellite_ring_growth_per_extra
  end

  @doc """
  Standard SVG polar-to-cartesian conversion (positive Y is down; no Y-flip —
  same convention as the dummy's own `Math.cos`/`Math.sin` usage).
  """
  @spec polar_to_cartesian(number(), number()) :: {float(), float()}
  def polar_to_cartesian(angle_degrees, radius) do
    radians = angle_degrees * :math.pi() / 180.0
    {radius * :math.cos(radians), radius * :math.sin(radians)}
  end

  @doc """
  `{x1, y1, x2, y2}` for a straight edge from node `a` to node `b`, shortened
  at each end by that end's own `radius + 4px` (spec §2 "node edge + 4px";
  mirrors the dummy's `edge()` function exactly).
  """
  @spec trim_edge(%{x: number(), y: number(), r: number()}, %{
          x: number(),
          y: number(),
          r: number()
        }) :: {float(), float(), float(), float()}
  def trim_edge(a, b) do
    dx = b.x - a.x
    dy = b.y - a.y
    len = :math.sqrt(dx * dx + dy * dy)
    ux = dx / len
    uy = dy / len

    {
      a.x + ux * (a.r + @edge_padding),
      a.y + uy * (a.r + @edge_padding),
      b.x - ux * (b.r + @edge_padding),
      b.y - uy * (b.r + @edge_padding)
    }
  end

  @doc """
  The full computed radial layout for `domains` (a list of
  `%{key: String.t(), satellites: [String.t()]}`, first-observed order):

    * `nebu` — always `%{x: 0.0, y: 0.0, r: 52}`.
    * `domains` — `%{domain_key => %{x, y, r, angle}}`, on the R1=300 ring.
    * `satellites` — `%{satellite_key => %{x, y, r, angle, domain}}`; the
      absolute position is the PARENT DOMAIN's position plus the satellite's
      own polar offset on the R2 ring (`satellite_ring/1` — grows with that
      domain's own satellite count, not a fixed radius).
  """
  @spec layout([%{key: String.t(), satellites: [String.t()]}]) :: %{
          nebu: map(),
          domains: %{String.t() => map()},
          satellites: %{String.t() => map()}
        }
  def layout(domains) do
    angle_by_key = domains |> Enum.map(& &1.key) |> domain_angles() |> Map.new()

    domain_map =
      Map.new(domains, fn %{key: key} ->
        angle = Map.fetch!(angle_by_key, key)
        {x, y} = polar_to_cartesian(angle, @domain_ring)
        {key, %{x: x, y: y, r: @domain_radius, angle: angle}}
      end)

    satellite_map =
      domains
      |> Enum.flat_map(fn %{key: domain_key, satellites: satellites} ->
        domain = Map.fetch!(domain_map, domain_key)
        count = length(satellites)
        angles = if satellites == [], do: [], else: satellite_angles(domain.angle, count)
        ring = satellite_ring(count)

        satellites
        |> Enum.zip(angles)
        |> Enum.map(fn {satellite_key, angle} ->
          {dx, dy} = polar_to_cartesian(angle, ring)

          {satellite_key,
           %{
             x: domain.x + dx,
             y: domain.y + dy,
             r: @satellite_radius,
             angle: angle,
             domain: domain_key
           }}
        end)
      end)
      |> Map.new()

    %{
      nebu: %{x: 0.0, y: 0.0, r: @center_radius},
      domains: domain_map,
      satellites: satellite_map
    }
  end
end
