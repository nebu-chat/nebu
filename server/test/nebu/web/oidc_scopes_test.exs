defmodule Nebu.Web.OidcScopesTest do
  @moduledoc """
  RED-phase ATDD tests for story `centralize-scope-resolution` (epic
  `oidc-simplification`).

  ## What is under test

  A brand-new module `Nebu.Web.OidcScopes` (does not exist yet — every test in this
  file fails with `UndefinedFunctionError` / `Nebu.Web.OidcScopes.__info__/1` errors
  until the dev agent implements `server/lib/nebu/web/oidc_scopes.ex`) becomes the
  SINGLE source of OIDC scope resolution + validation, replacing:

    * `Nebu.Matrix.SsoLogin.scope_list/0` (+ `matrix_extra_scopes/0` + `matrix_refresh_mode/0`)
    * `Nebu.Admin.Auth.admin_oidc_scope/0` (+ `union_scopes/2` + the two `*_extra_scopes/refresh_mode`
      readers) — including the Admin→Matrix facade fold via `Nebu.Matrix.matrix_oidc_extra_scopes/0`
    * The two duplicated `~r/^[a-zA-Z0-9_:.\\-]+\\z/` scope validators in
      `bootstrap_controller.ex` and `admin/auth.ex`.

  ## Acceptance criteria covered

    * AC1 — `resolve_scope/1` + `validate_scope_string/1` public API shape.
    * AC2 — scope cache extends `Nebu.Web.OidcConfig`'s existing ETS/`:pg` pattern
      (asserted via the migrated reader seams + a cache-invalidation smoke test, PLUS
      an `@integration`-tagged suite that seeds real `server_config` rows and drives
      the actual `OidcConfig.refresh/0` ETS/`:pg` path with no seam override — see
      "AC2 (integration)" describe block below).
    * AC3 — `offline_access` no longer leaks from Matrix's extra-scope config into
      the Admin scope union (MUST-FIX, Kassandra LOW).
    * AC4 — Matrix/Admin become thin call-sites; the `Nebu.Matrix.matrix_oidc_extra_scopes/0`
      facade delegate is removed (structural / grep-style checks against the source files).
    * AC5 — Bootstrap + Admin-Config controllers call the ONE validator (structural
      grep checks — no local regex copy left in either controller file).
    * AC6 — OIDC Scopes Law stays mechanically enforced: no `server_config` entry ⇒
      `resolve_scope/1` returns `"openid"` alone (+ `offline_access` iff offline).
    * AC7 — regression: a scope token with a trailing `"\\n"` must be rejected by the
      ONE validator (`\\z`, not `$`).

  ## Seam design (per Implementation Map: "one set of seams instead of four separate
  ones", now living on `Nebu.Web.OidcScopes` / read through it)

  This story keeps the EXISTING seam names/shapes (they migrate house, not shape) so
  the six regression suites named in AC7 keep passing unmodified against the new
  module:

    * `:matrix_oidc_extra_scopes_reader` — 0-arity fun, Matrix extra scopes.
    * `:matrix_oidc_refresh_mode_reader` — 0-arity fun, Matrix refresh mode.
    * `:admin_oidc_extra_scopes_reader` — 0-arity fun, Admin extra scopes.
    * `:admin_oidc_refresh_mode_reader` — 0-arity fun, Admin refresh mode.

  `OidcScopes.resolve_scope/1` must consult these SAME seams (not a new set) so the
  existing `sso_login_scope_test.exs`, `admin_scope_mode_test.exs`,
  `admin_bootstrap_groups_scope_test.exs` etc. — which drive scope resolution via the
  PUBLIC HTTP surface (redirect `scope` query param), not by calling `OidcScopes`
  directly — continue to observe the same behavior once `SsoLogin`/`Auth` delegate.

  ## Why every test here is RED right now

  `Nebu.Web.OidcScopes` does not exist. `Code.ensure_loaded?/1` returns `false` and
  any direct call raises `UndefinedFunctionError`. The structural (AC4/AC5/AC6) tests
  are RED against the CURRENT source (facade delegate still present, controllers still
  contain local regex, admin/auth.ex still calls `Nebu.Matrix` and still folds Matrix
  scopes unfiltered into the admin union).
  """
  use ExUnit.Case, async: false

  alias Nebu.Web.OidcScopes

  @lib_root Path.expand("../../../lib/nebu", __DIR__)

  setup do
    on_exit(fn ->
      for k <- [
            :matrix_oidc_extra_scopes_reader,
            :matrix_oidc_refresh_mode_reader,
            :admin_oidc_extra_scopes_reader,
            :admin_oidc_refresh_mode_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — Nebu.Web.OidcScopes exists and exposes resolve_scope/1 + validate_scope_string/1
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1: module + public API shape" do
    test "Nebu.Web.OidcScopes module exists" do
      assert Code.ensure_loaded?(Nebu.Web.OidcScopes),
             "Nebu.Web.OidcScopes does not exist yet — expected at server/lib/nebu/web/oidc_scopes.ex"
    end

    test "resolve_scope/1 is exported and accepts :matrix" do
      assert function_exported?(OidcScopes, :resolve_scope, 1)
      set_matrix(extra: "", mode: "online")
      assert is_binary(OidcScopes.resolve_scope(:matrix))
    end

    test "resolve_scope/1 accepts :admin" do
      set_admin(extra: "", mode: "online")
      assert is_binary(OidcScopes.resolve_scope(:admin))
    end

    test "validate_scope_string/1 is exported and returns :ok for a valid string" do
      assert function_exported?(OidcScopes, :validate_scope_string, 1)
      assert OidcScopes.validate_scope_string("profile email groups") == :ok
    end

    test "validate_scope_string/1 returns {:error, String.t()} for an invalid token" do
      assert {:error, msg} = OidcScopes.validate_scope_string("profile email!")
      assert is_binary(msg)
    end

    test "validate_scope_string/1 accepts the empty string (openid-only is valid)" do
      assert OidcScopes.validate_scope_string("") == :ok
    end

    test "resolve_scope/1 result is deduplicated" do
      set_matrix(extra: "profile profile email", mode: "online")
      scopes = OidcScopes.resolve_scope(:matrix) |> String.split(" ", trim: true)
      assert scopes == Enum.uniq(scopes), "resolve_scope/1 must deduplicate tokens"
    end

    test "resolve_scope/1 result is space-separated" do
      set_matrix(extra: "profile email", mode: "online")
      scope = OidcScopes.resolve_scope(:matrix)
      assert scope =~ " "
      refute scope =~ ","
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 — OIDC Scopes Law: no server_config entry ⇒ "openid" alone (mechanically enforced)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6: OIDC Scopes Law — default is openid only, never a hardcoded extra" do
    test "matrix: no configured extra scope + online ⇒ exactly 'openid'" do
      set_matrix(extra: "", mode: "online")
      assert OidcScopes.resolve_scope(:matrix) == "openid"
    end

    test "matrix: no configured extra scope + offline ⇒ exactly 'openid offline_access' (order-independent)" do
      set_matrix(extra: "", mode: "offline")
      scopes = OidcScopes.resolve_scope(:matrix) |> String.split(" ", trim: true)
      assert Enum.sort(scopes) == Enum.sort(["openid", "offline_access"])
    end

    test "admin: no configured extra scope + online ⇒ exactly 'openid'" do
      set_admin(extra: "", mode: "online")
      assert OidcScopes.resolve_scope(:admin) == "openid"
    end

    test "admin: no configured extra scope + offline ⇒ exactly 'openid offline_access' (order-independent)" do
      set_admin(extra: "", mode: "offline")
      scopes = OidcScopes.resolve_scope(:admin) |> String.split(" ", trim: true)
      assert Enum.sort(scopes) == Enum.sort(["openid", "offline_access"])
    end

    test "matrix: absent seam (nil) never yields profile/email/groups" do
      set_matrix(extra: nil, mode: "online")
      scope = OidcScopes.resolve_scope(:matrix)

      refute scope =~ "profile"
      refute scope =~ "email"
      refute scope =~ "groups"
      assert scope == "openid"
    end

    test "admin: absent seam (nil) never yields profile/email/groups" do
      set_admin(extra: nil, mode: "online")
      scope = OidcScopes.resolve_scope(:admin)

      refute scope =~ "profile"
      refute scope =~ "email"
      refute scope =~ "groups"
      assert scope == "openid"
    end

    test "grep LAW: oidc_scopes.ex contains no hardcoded profile/email/groups scope literal" do
      # Code-review-grep rule (AC6): no literal string with more than "openid" may
      # appear as a default scope value in the new module's source.
      path = Path.join(@lib_root, "web/oidc_scopes.ex")

      assert File.exists?(path),
             "server/lib/nebu/web/oidc_scopes.ex does not exist yet"

      source = File.read!(path)

      refute source =~ ~r/"openid profile/,
             "OIDC Scopes Law violation: hardcoded 'openid profile...' default literal found in oidc_scopes.ex"

      refute source =~ ~r/\["profile"|"profile email"|"profile email groups"/,
             "OIDC Scopes Law violation: hardcoded extra-scope literal found in oidc_scopes.ex"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — offline_access must NOT leak from Matrix's extra scopes into the Admin union
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3: offline_access does not leak across the Matrix/Admin scope boundary" do
    test "regression (story-specified): matrix_oidc_extra_scopes contains offline_access, admin stays online ⇒ Admin scope excludes offline_access" do
      set_matrix(extra: "profile offline_access", mode: "online")
      set_admin(extra: "", mode: "online")

      admin_scope = OidcScopes.resolve_scope(:admin)

      refute admin_scope =~ "offline_access",
             "offline_access leaked from matrix_oidc_extra_scopes into the Admin scope request: #{admin_scope}"
    end

    test "Admin scope requests offline_access ONLY via its own refresh mode, never via Matrix's" do
      set_matrix(extra: "offline_access", mode: "offline")
      set_admin(extra: "", mode: "online")

      admin_scope = OidcScopes.resolve_scope(:admin)
      refute admin_scope =~ "offline_access"

      matrix_scope = OidcScopes.resolve_scope(:matrix)
      assert matrix_scope =~ "offline_access"
    end

    test "conversely, admin_oidc_extra_scopes containing offline_access does not leak into Matrix" do
      set_admin(extra: "offline_access", mode: "online")
      set_matrix(extra: "", mode: "online")

      matrix_scope = OidcScopes.resolve_scope(:matrix)

      refute matrix_scope =~ "offline_access",
             "offline_access leaked from admin_oidc_extra_scopes into the Matrix scope request: #{matrix_scope}"
    end

    test "when Admin's OWN refresh mode is offline, offline_access IS present (own-mode path still works)" do
      set_matrix(extra: "profile offline_access", mode: "online")
      set_admin(extra: "", mode: "offline")

      admin_scope = OidcScopes.resolve_scope(:admin)
      assert admin_scope =~ "offline_access"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — scope cache extends the existing OidcConfig ETS/:pg pattern
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2: scope cache reuses the OidcConfig cache mechanism (no ad-hoc SQL, no node-local-only cache)" do
    test "resolve_scope/1 honours the migrated reader seams (same seam names as before centralization)" do
      # AC2 + Implementation Map: the existing per-domain reader seams migrate to
      # OidcScopes rather than being replaced by a new, incompatible set — this keeps
      # sso_login_scope_test.exs / admin_scope_mode_test.exs etc. green with no changes.
      set_matrix(extra: "custom_scope_x", mode: "online")
      assert OidcScopes.resolve_scope(:matrix) =~ "custom_scope_x"
    end

    test "grep: oidc_scopes.ex reads through Nebu.Web.OidcConfig's cache table, not ad-hoc SQL" do
      path = Path.join(@lib_root, "web/oidc_scopes.ex")
      assert File.exists?(path), "server/lib/nebu/web/oidc_scopes.ex does not exist yet"

      source = File.read!(path)

      refute source =~ ~r/Ecto\.Adapters\.SQL\.query/,
             "AC2/AC4 violation: OidcScopes must read via the shared ETS cache " <>
               "(extending Nebu.Web.OidcConfig), not run its own ad-hoc server_config SQL"
    end

    test "grep: oidc_config.ex's ETS table gains the four new scope/refresh-mode keys" do
      path = Path.join(@lib_root, "web/oidc_config.ex")
      source = File.read!(path)

      for key <- ~w(matrix_oidc_extra_scopes matrix_oidc_refresh_mode admin_oidc_extra_scopes admin_oidc_refresh_mode) do
        assert source =~ key,
               "AC2 violation: Nebu.Web.OidcConfig's cached-key set must be extended with " <>
                 "'#{key}' (currently only issuer/audience/jwks_uri); got source without it"
      end
    end

    test "cache invalidation is cluster-wide: refreshing OidcConfig also refreshes scope values (no stale node-local cache)" do
      # AC2 hard requirement: "kein node-lokaler Cache ohne Cluster-Invalidierung". We
      # cannot easily simulate a second BEAM node in a unit test, but we CAN assert
      # that OidcConfig's existing refresh/:pg-broadcast path is the one actually
      # consulted — i.e. there is no SEPARATE, independently-lived scope cache that
      # `Nebu.Web.OidcConfig.refresh/0` does not know about. A passing implementation
      # extends the SAME ETS table/GenServer rather than spinning up a second cache
      # process; this smoke test just confirms `refresh/0` does not crash and that a
      # subsequent resolve_scope/1 reflects a seam change (best-effort behavioral proxy
      # for "no separate, unreachable cache" — the grep test above pins architecture).
      set_matrix(extra: "before_refresh", mode: "online")
      assert OidcScopes.resolve_scope(:matrix) =~ "before_refresh"

      set_matrix(extra: "after_refresh", mode: "online")
      assert OidcScopes.resolve_scope(:matrix) =~ "after_refresh",
             "resolve_scope/1 must observe a config change without requiring a separate, " <>
               "OidcConfig-unaware cache-refresh call"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 (integration) — the REAL ETS/:pg cache path, no seam override
  #
  # The unit tests above intentionally use the :{matrix,admin}_oidc_*_reader seams
  # (that's the documented, correct way to unit-test scope resolution without a DB).
  # But a seam-only suite cannot distinguish "OidcScopes correctly extends the shared
  # OidcConfig ETS table" from "OidcScopes secretly maintains its own separate,
  # node-local, :pg-unaware cache" — both would look identical through the seam. This
  # integration test closes that gap: it seeds `server_config` directly in Postgres,
  # calls `Nebu.Web.OidcConfig.refresh/0` on the REAL named GenServer/ETS table (no
  # seam), and asserts `resolve_scope/1` observes the DB-backed value. An
  # implementation with a second, unreachable-by-refresh/0 cache would fail this test
  # because refresh/0 would never populate whatever table that implementation reads.
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 (integration): resolve_scope/1 reflects server_config via the REAL OidcConfig ETS/:pg path" do
    @describetag :integration

    setup do
      # Ensure no unit-test seam is left set from a prior test in this file — this
      # test must exercise resolve_scope/1's DEFAULT (non-seam) path, i.e. whatever
      # OidcScopes falls back to when no :*_reader seam is configured, which per the
      # Implementation Map is the extended Nebu.Web.OidcConfig ETS cache.
      for k <- [
            :matrix_oidc_extra_scopes_reader,
            :matrix_oidc_refresh_mode_reader,
            :admin_oidc_extra_scopes_reader,
            :admin_oidc_refresh_mode_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end

      # `server_config` has no DELETE policy under FORCE ROW LEVEL SECURITY (only
      # SELECT/INSERT/UPDATE are granted — see migrations 000001/000007/000013), so a
      # bare DELETE silently affects 0 rows for the nebu_app role. Reset to a neutral
      # "" via the same INSERT ... ON CONFLICT DO UPDATE upsert the app itself uses
      # (Nebu.Admin.DB.upsert_server_config/1) instead of relying on DELETE.
      upsert_server_config("matrix_oidc_extra_scopes", "")
      upsert_server_config("admin_oidc_extra_scopes", "")

      # OidcConfig is gated off under `mix test` (config/test.exs: start_jwks_cache:
      # false) so the app-level supervision tree never starts it. Start (or reuse) the
      # REAL named GenServer here so refresh/0 (no seam) exercises the actual ETS
      # table + :pg group this story's AC2 requires OidcScopes to extend.
      case Nebu.Web.OidcConfig.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      :ok = Nebu.Web.OidcConfig.refresh()

      on_exit(fn ->
        upsert_server_config("matrix_oidc_extra_scopes", "")
        upsert_server_config("admin_oidc_extra_scopes", "")

        if pid = Process.whereis(Nebu.Web.OidcConfig) do
          if Process.alive?(pid), do: Nebu.Web.OidcConfig.refresh()
        end
      end)

      :ok
    end

    test "matrix: resolve_scope/1 reflects a server_config value ONLY visible after OidcConfig.refresh/0 (real ETS path)" do
      upsert_server_config("matrix_oidc_extra_scopes", "ac2_integration_probe")
      upsert_server_config("matrix_oidc_refresh_mode", "online")

      # Before refresh/0, the ETS cache must not yet reflect the just-inserted row
      # (proves resolve_scope/1 is reading a CACHE, not doing its own ad-hoc SQL —
      # if it read the DB directly on every call, this pre-refresh assertion would be
      # meaningless because it would already see the new value).
      refute OidcScopes.resolve_scope(:matrix) =~ "ac2_integration_probe",
             "resolve_scope/1 must read through the ETS cache, not re-query server_config " <>
               "directly on every call — a direct SQL read would already see this value " <>
               "before refresh/0, defeating the whole purpose of the cache"

      :ok = Nebu.Web.OidcConfig.refresh()

      assert OidcScopes.resolve_scope(:matrix) =~ "ac2_integration_probe",
             "AC2 violation: after Nebu.Web.OidcConfig.refresh/0 (the SAME refresh path " <>
               "used by issuer/audience/jwks_uri), resolve_scope/1 must observe the " <>
               "server_config-backed value — a separate, :pg-unaware cache would fail here"
    end

    test "admin: resolve_scope/1 reflects a server_config value only after the real refresh/0 path" do
      upsert_server_config("admin_oidc_extra_scopes", "ac2_admin_probe")
      upsert_server_config("admin_oidc_refresh_mode", "online")

      refute OidcScopes.resolve_scope(:admin) =~ "ac2_admin_probe"

      :ok = Nebu.Web.OidcConfig.refresh()

      assert OidcScopes.resolve_scope(:admin) =~ "ac2_admin_probe",
             "AC2 violation: Nebu.Web.OidcConfig.refresh/0 must repopulate the scope keys " <>
               "for :admin exactly as it does for :matrix and for issuer/audience/jwks_uri"
    end

    test "refresh/0 broadcasts via the SAME :pg group OidcConfig already uses (no second, unbroadcast cache)" do
      # AC2: cache invalidation MUST ride the existing :pg broadcast (M-3/ADR-020), not
      # a second mechanism. We can't spin up a real second BEAM node in this suite, but
      # we CAN assert that the process implementing the scope cache is a MEMBER of the
      # documented :pg group — i.e. it's the same GenServer, not a look-alike process
      # nobody's peer-refresh would ever reach.
      #
      # NOTE: this specific assertion is already true TODAY (Nebu.Web.OidcConfig
      # already joins its own :pg group regardless of this story) — it is a precondition
      # guard, not a RED-must-fail behavioral test. It stays green throughout the
      # refactor and continues to guard against a future regression where scope
      # resolution is accidentally moved onto a second, non-member cache process. The
      # two tests above it in this describe block ARE the RED-phase behavioral tests
      # for AC2 (both fail today with UndefinedFunctionError, as expected).
      members = :pg.get_members(Nebu.Web.OidcConfig.pg_group())

      assert Process.whereis(Nebu.Web.OidcConfig) in members,
             "AC2: the process serving OidcScopes' cached values must be a member of " <>
               "Nebu.Web.OidcConfig's existing :pg group (#{Nebu.Web.OidcConfig.pg_group()}) " <>
               "— a second, non-member cache process would never receive a peer-node " <>
               "invalidation broadcast, reintroducing the stale-config bug AC2 forbids"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — Matrix and Admin become thin call-sites; obsolete facade delegate removed
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4: Nebu.Matrix.SsoLogin and Nebu.Admin.Auth are thin call-sites" do
    test "Nebu.Matrix.matrix_oidc_extra_scopes/0 facade delegate is REMOVED (obsolete)" do
      # NOTE: function_exported?/3 answers `false` for a module that has not yet been
      # loaded in the current process — Code.ensure_loaded/1 first is REQUIRED, or this
      # assertion would false-pass today (the facade delegate still exists in matrix.ex).
      {:module, Nebu.Matrix} = Code.ensure_loaded(Nebu.Matrix)

      refute function_exported?(Nebu.Matrix, :matrix_oidc_extra_scopes, 0),
             "AC4: the Nebu.Matrix.matrix_oidc_extra_scopes/0 facade delegate must be " <>
               "removed once Nebu.Admin.Auth no longer folds Matrix's scopes via the facade"
    end

    test "grep: sso_login.ex contains no scope-related server_config SQL read (delegates to OidcScopes)" do
      # Scoped narrowly to the scope-resolution SQL constants only — analogous to the
      # admin/auth.ex test below ("no server_config SQL read for scopes"). sso_login.ex
      # legitimately keeps its unrelated `config_value/1` / `@sql_config` SQL read for
      # OIDC CLIENT CREDENTIALS (client_id/client_secret resolution,
      # resolve_client_credentials/0) — out of scope for this story (Implementation Map
      # only lists scope_list/0 as changing). A blanket "no Ecto.Adapters.SQL.query at
      # all" assertion would be unsatisfiable even by a fully correct, in-scope refactor
      # (same class of issue as the AC4 admin/auth.ex MAJOR-1 finding, narrowed the same
      # way here).
      path = Path.join(@lib_root, "matrix/sso_login.ex")
      source = File.read!(path)

      refute source =~ "@sql_matrix_extra_scopes",
             "AC4: Nebu.Matrix.SsoLogin must no longer define its own matrix-extra-scopes SQL constant"

      refute source =~ "@sql_matrix_refresh_mode",
             "AC4: Nebu.Matrix.SsoLogin must no longer define its own matrix-refresh-mode SQL constant"
    end

    test "grep: sso_login.ex contains no local scope-validation regex" do
      path = Path.join(@lib_root, "matrix/sso_login.ex")
      source = File.read!(path)

      refute source =~ ~r/\^\[a-zA-Z0-9_:\.\\?-\]\+/,
             "AC4: Nebu.Matrix.SsoLogin must not contain its own scope-validation regex"
    end

    test "grep: sso_login.ex calls Nebu.Web.OidcScopes for scope resolution" do
      path = Path.join(@lib_root, "matrix/sso_login.ex")
      source = File.read!(path)

      assert source =~ "OidcScopes",
             "AC4: Nebu.Matrix.SsoLogin.scope_list/0 must delegate to Nebu.Web.OidcScopes.resolve_scope/1"
    end

    test "grep: admin/auth.ex contains no server_config SQL read for scopes (delegates to OidcScopes)" do
      path = Path.join(@lib_root, "admin/auth.ex")
      source = File.read!(path)

      refute source =~ "@sql_admin_extra_scopes",
             "AC4: Nebu.Admin.Auth must no longer define its own admin-extra-scopes SQL constant"

      refute source =~ "@sql_admin_refresh_mode",
             "AC4: Nebu.Admin.Auth must no longer define its own admin-refresh-mode SQL constant"
    end

    test "grep: admin/auth.ex contains no local scope-validation regex" do
      path = Path.join(@lib_root, "admin/auth.ex")
      source = File.read!(path)

      refute source =~ ~r/\^\[a-zA-Z0-9_:\.\\?-\]\+/,
             "AC4: Nebu.Admin.Auth must not contain its own scope-validation regex"
    end

    test "grep: admin/auth.ex no longer calls into the Nebu.Matrix domain for SCOPES (ADR-020)" do
      # Scoped narrowly to the scope-resolution call path only. admin/auth.ex legitimately
      # keeps unrelated, out-of-scope Nebu.Matrix references for identity/claim resolution
      # (Nebu.Matrix.UserId.from_claims/2) and OIDC metadata discovery
      # (Nebu.Matrix.OidcMetadata.fetch/1) — this story's Non-Goals explicitly exclude
      # claim-mapping ("Kein Claim-Mapping"), so a correct AC4 implementation must NOT
      # remove those. A blanket "no Nebu.Matrix reference at all" assertion would be
      # unsatisfiable even by a fully correct, in-scope refactor.
      path = Path.join(@lib_root, "admin/auth.ex")
      source = File.read!(path)

      refute source =~ "Nebu.Matrix.matrix_oidc_extra_scopes",
             "AC4: Nebu.Admin.Auth must not call Nebu.Matrix (facade or otherwise) for scopes " <>
               "— it must call Nebu.Web.OidcScopes only"

      refute source =~ ~r/Nebu\.Matrix\.matrix_oidc_extra_scopes|matrix_oidc_extra_scopes\(\)/,
             "AC4: no residual call site (direct or facade-mediated) into the Matrix domain " <>
               "for scope resolution may remain in Nebu.Admin.Auth"
    end

    test "grep: admin/auth.ex delegates to Nebu.Web.OidcScopes for its scope" do
      path = Path.join(@lib_root, "admin/auth.ex")
      source = File.read!(path)

      assert source =~ "OidcScopes",
             "AC4: Nebu.Admin.Auth.admin_oidc_scope/0 must delegate to Nebu.Web.OidcScopes.resolve_scope/1"
    end

    test "grep: admin/auth.ex no longer defines union_scopes/2" do
      path = Path.join(@lib_root, "admin/auth.ex")
      source = File.read!(path)

      refute source =~ "union_scopes",
             "AC4: the union_scopes/2 fold (root cause of the AC3 offline_access leak) " <>
               "must be removed from Nebu.Admin.Auth entirely"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — Bootstrap + Admin-Config controllers use the ONE validator
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5: bootstrap_controller.ex and config_controller.ex call the ONE validator" do
    test "grep: bootstrap_controller.ex has no local validate_scope_string/1 regex copy" do
      path = Path.join(@lib_root, "admin/bootstrap_controller.ex")
      source = File.read!(path)

      refute source =~ ~r/defp\s+validate_scope_string/,
             "AC5: bootstrap_controller.ex must not define its own validate_scope_string/1 " <>
               "— it must call Nebu.Web.OidcScopes.validate_scope_string/1"
    end

    test "grep: bootstrap_controller.ex calls Nebu.Web.OidcScopes.validate_scope_string/1" do
      path = Path.join(@lib_root, "admin/bootstrap_controller.ex")
      source = File.read!(path)

      assert source =~ "OidcScopes.validate_scope_string",
             "AC5: bootstrap_controller.ex save_step3/2 must call Nebu.Web.OidcScopes.validate_scope_string/1"
    end

    test "grep: config_controller.ex has no local scope-validation regex" do
      path = Path.join(@lib_root, "admin/config_controller.ex")
      source = File.read!(path)

      refute source =~ ~r/\^\[a-zA-Z0-9_:\.\\?-\]\+/,
             "AC5: config_controller.ex save_scopes/2 must not contain its own scope-validation regex"
    end

    test "grep: config_controller.ex calls Nebu.Web.OidcScopes.validate_scope_string/1" do
      path = Path.join(@lib_root, "admin/config_controller.ex")
      source = File.read!(path)

      assert source =~ "OidcScopes.validate_scope_string",
             "AC5: config_controller.ex save_scopes/2 must call Nebu.Web.OidcScopes.validate_scope_string/1"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 — validate_scope_string/1 rejects a trailing "\n" (\z anchor, not $)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7: \\z anchor — trailing newline is rejected, not just embedded newline" do
    test "a scope token with a trailing newline is rejected" do
      assert {:error, _msg} = OidcScopes.validate_scope_string("profile email\n"),
             "validate_scope_string/1 must reject a trailing '\\n' — a regex anchored with " <>
               "$ instead of \\z would wrongly accept this (Ruby/PCRE $ matches before a trailing \\n)"
    end

    test "a scope token with an embedded newline is rejected" do
      assert {:error, _msg} = OidcScopes.validate_scope_string("profile\nemail")
    end

    test "a plain valid multi-token scope string is accepted (no false positive from the anchor fix)" do
      assert OidcScopes.validate_scope_string("profile email groups") == :ok
    end

    test "a single token with a trailing newline is rejected" do
      assert {:error, _msg} = OidcScopes.validate_scope_string("groups\n")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp set_matrix(extra: extra, mode: mode) do
    Application.put_env(:nebu_http, :matrix_oidc_extra_scopes_reader, fn -> extra end)
    Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> mode end)
  end

  defp set_admin(extra: extra, mode: mode) do
    Application.put_env(:nebu_http, :admin_oidc_extra_scopes_reader, fn -> extra end)
    Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> mode end)
  end

  # `server_config` has FORCE ROW LEVEL SECURITY with SELECT/INSERT/UPDATE policies
  # but NO DELETE policy at all (migrations 000001/000007/000013) — a bare DELETE
  # silently affects 0 rows for the nebu_app role, it does not raise. Use the exact
  # same INSERT ... ON CONFLICT DO UPDATE upsert the app itself uses
  # (Nebu.Admin.DB.upsert_server_config/1) so seeding works whether the row exists
  # yet or not; all four scope/refresh-mode keys used here are on the UPDATE
  # allowlist (migration 000013_config_oidc_scopes_mutable, plus 000007 for the
  # refresh-mode keys).
  defp upsert_server_config(key, value) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO server_config (key, value, set_at)
      VALUES ($1, $2, $3)
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at
      """,
      [key, value, System.system_time(:millisecond)]
    )
  end
end
