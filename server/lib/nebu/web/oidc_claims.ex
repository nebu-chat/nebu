defmodule Nebu.Web.OidcClaims do
  @moduledoc """
  Shared recursive claim-traversal helpers for OIDC claim maps.

  ## Purpose

  Both the Admin OIDC login gate (`Nebu.Admin.Auth.admin_claim?/1`) and the
  Bootstrap Wizard's claim-picker (`Nebu.Admin.Auth.extract_discovered_claims/1`)
  need to walk the same shape of data: a decoded OIDC claims map that may nest
  arbitrarily deep (Keycloak-shaped claims such as `realm_access.roles` or
  `resource_access.<client>.roles` vs. flat Dex-style `"groups" => [...]`
  claims). This module centralizes that traversal so both call sites share one
  implementation instead of maintaining two independent recursive walkers that
  could drift apart (as happened historically — both were extended from flat to
  recursive in the same bugfix, at two separate call sites).

  This module is intentionally a pure, stateless set of functions — no process,
  no config, no external dependency (ADR-018: no domain model / repository
  layer; ADR-020: `Nebu.Web` is shared infra used across domains).

  ## Interface

  - `claim_value_matches?/2` — recursive value matcher; true when `target` is
    present anywhere in `value` at any nesting depth.
  - `flatten_discovered_claims/2` — flattens a claims map into `{dot_path_key,
    value}` pairs, used to render the Bootstrap Wizard's claim-picker options.
  - `claim_at_path_matches?/3` — PATH-scoped value matcher (story
    `scope-admin-claim-to-path`): true only when `target` is present at the
    exact dot-path in `claims`, not anywhere in the tree.
  """

  # SEC NOTE / rationale for the two recursive walkers below (carried over
  # verbatim from `Nebu.Admin.Auth` during the `centralize-claim-resolution`
  # refactor — AC3):
  #
  # Recursively walks a claims value (map, list, or scalar) looking for
  # `target` as a string value, or as a member of a list of strings, at any
  # nesting depth.
  #
  # Non-tail-recursive with no explicit depth guard: acceptable because (a)
  # `target` (from `admin_group_claim/0`, or any other caller-supplied match
  # target) is always a binary — DB-guarded or the literal default — never
  # attacker-controlled, and (b) the recursion depth is bounded in practice by
  # the JSON structure of a trusted, signature-verified IdP token, not by
  # adversarial input in any sense that matters here — the IdP is already the
  # trust anchor for the whole authentication flow.

  @doc """
  True when `target` is present anywhere inside `value` — as an exact binary
  match, as a member of a list, or nested inside a map/list at any depth.
  """
  @spec claim_value_matches?(term(), binary()) :: boolean()
  def claim_value_matches?(target, target) when is_binary(target), do: true

  def claim_value_matches?(map, target) when is_map(map) do
    Enum.any?(map, fn {_k, v} -> claim_value_matches?(v, target) end)
  end

  def claim_value_matches?(list, target) when is_list(list) do
    target in list or Enum.any?(list, &claim_value_matches?(&1, target))
  end

  def claim_value_matches?(_, _), do: false

  @doc """
  Flattens an OIDC claims value into `{dot_path_key, value}` pairs.

  Descends recursively through arbitrary nesting so IdP-shaped claims such as
  Keycloak's `realm_access.roles` or `resource_access.<client>.roles` are
  surfaced too, not just flat Dex-style claims. Nested entries use a dot-path
  key (e.g. `"realm_access.roles"`); flat claims keep their original bare key.

  Does not de-duplicate — the caller (`Nebu.Admin.Auth.extract_discovered_claims/1`)
  is responsible for `Enum.uniq/1` on the result.
  """
  @spec flatten_discovered_claims(term(), String.t() | nil) :: [{String.t() | nil, String.t()}]
  def flatten_discovered_claims(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      flatten_discovered_claims(v, dot_path(prefix, k))
    end)
  end

  def flatten_discovered_claims(list, prefix) when is_list(list) do
    Enum.flat_map(list, fn item -> flatten_discovered_claims(item, prefix) end)
  end

  def flatten_discovered_claims(s, prefix) when is_binary(s) and s != "" do
    [{prefix, s}]
  end

  def flatten_discovered_claims(_, _), do: []

  defp dot_path(nil, key), do: key
  defp dot_path(prefix, key), do: "#{prefix}.#{key}"

  # ── Path-scoped matcher (story scope-admin-claim-to-path) ──────────────────────
  #
  # SEC (closes Kassandra MEDIUM, bugfix-unify-admin-matrix-oidc-identity +
  # bugfix-nested-oidc-claim-support, both 2026-07-01): `claim_value_matches?/2`
  # above matches `target` against EVERY value in the claims tree, regardless of
  # which key/path it appears under. That means a non-admin whose IdP lets them
  # self-set an unrelated claim (e.g. `name`, `preferred_username`,
  # `address.locality`) to the configured admin-marker value would be
  # misclassified as admin. `claim_at_path_matches?/3` fixes this by resolving
  # ONLY the value(s) at `path` (a dot-path string, e.g. `"realm_access.roles"`
  # or a flat `"groups"`) and matching `target` against just that subtree — a
  # hit anywhere else in the claims map does not count.

  @doc """
  True when `target` is present in `claims` at the exact `path` (dot-path
  string, e.g. `"realm_access.roles"` or a flat `"groups"`) — as an exact
  binary match, a list member, or nested inside a map/list at any depth
  *below* that path. A hit anywhere else in the claims tree does NOT count.

  Returns `false` when `path` is `nil`/empty or resolves to nothing (fails
  closed — an unset/misconfigured path never grants admin).
  """
  @spec claim_at_path_matches?(map(), String.t() | nil, binary()) :: boolean()
  def claim_at_path_matches?(claims, path, target)
      when is_map(claims) and is_binary(path) and path != "" and is_binary(target) do
    case resolve_path(claims, String.split(path, ".")) do
      {:ok, value} -> claim_value_matches?(value, target)
      :error -> false
    end
  end

  def claim_at_path_matches?(_claims, _path, _target), do: false

  defp resolve_path(value, []), do: {:ok, value}

  defp resolve_path(map, [segment | rest]) when is_map(map) do
    case Map.fetch(map, segment) do
      {:ok, value} -> resolve_path(value, rest)
      :error -> :error
    end
  end

  defp resolve_path(_value, _segments), do: :error
end
