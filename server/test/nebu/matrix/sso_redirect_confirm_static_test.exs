defmodule Nebu.Matrix.SsoRedirectConfirmStaticTest do
  @moduledoc """
  ATDD static acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), no DB: AC12 (the
  JsonBody / CORS / routing clauses of `/_matrix/client/v3/login/sso/confirm`) and AC17 (boundaries, facade
  exports with `@doc`, compile-guarded seams, no new env variable, no COOP in the new modules).

  Source scans strip `#` comments and cover alias forms (`alias Nebu.OAuth.{...}`), like
  `oauth_legacy_coexistence_static_test.exs`. The behaviour itself is covered by the flow / page / csrf tests.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  defp read(rel), do: File.read!(Path.join(@lib, rel))
  defp code(rel), do: rel |> read() |> strip_comments()
  # documentation heredocs (@moduledoc / @doc) and `#` comments are not code: prose may name modules or headers
  defp strip_comments(src), do: src |> String.replace(~r/"""[\s\S]*?"""/, "") |> String.replace(~r/#[^\n]*/, "")

  defp read_new!(rel) do
    path = Path.join(@lib, rel)
    assert File.exists?(path), "lib/#{rel} is missing (new module of this story)"
    path |> File.read!() |> strip_comments()
  end

  defp doc_of(mod, fun, arity) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, _, _, docs} ->
        Enum.find_value(docs, fn
          {{:function, ^fun, ^arity}, _, _, %{"en" => d}, _} -> d
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12 — routing clauses
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12 — the confirm route is wired" do
    test "HttpPublic routes GET and POST /sso/confirm to SsoConfirm.handle/1, before the M_UNRECOGNIZED fall-through" do
      src = code("nebu/matrix/http_public.ex")
      assert {get_i, _} = :binary.match(src, ~s(get "/sso/confirm")), ~s(get "/sso/confirm" missing)
      assert {post_i, _} = :binary.match(src, ~s(post "/sso/confirm")), ~s(post "/sso/confirm" missing)
      assert {marker_i, _} = :binary.match(src, "match _, private: %{nebu_unrecognized: true}")
      assert get_i < marker_i and post_i < marker_i, "the confirm routes must come BEFORE the fall-through"
      assert src =~ ~r/SsoConfirm\.handle/, "the routes call SsoConfirm.handle/1"
    end

    test "Router.cors/2 has a skip clause for the confirm path (browser navigation: no access-control-* header, no preflight)" do
      src = code("nebu/web/router.ex")

      assert src =~ ~r/defp cors\(%Plug\.Conn\{path_info: \["_matrix",\s*"client",\s*"v3",\s*"login",\s*"sso",\s*"confirm"\s*\|\s*_\]\}\s*=\s*conn,\s*_opts\),\s*do:\s*conn/,
             "cors/2 must skip CORSPlug for [\"_matrix\", \"client\", \"v3\", \"login\", \"sso\", \"confirm\" | _]"
    end

    test "JsonBody skips the confirm path (FormPost parses the form itself; body_params stay unfetched)" do
      src = code("nebu/web/plugs/json_body.ex")
      assert src =~ ~r/\[\s*"_matrix"\s*,\s*"client"\s*,\s*"v3"\s*,\s*"login"\s*,\s*"sso"\s*,\s*"confirm"\s*\|\s*_\s*\]/
    end

    test "RequestLogger masks the confirm path's query string names-only (@names_only_query_paths)" do
      src = code("nebu/web/plugs/request_logger.ex")
      assert [_, list] = Regex.run(~r/@names_only_query_paths\s*\[(.*?)\]/s, src)
      assert list =~ "/_matrix/client/v3/login/sso/confirm"
      assert list =~ "/_matrix/client/v3/login/sso/redirect/oidc", "the callback stays names-only"
    end

    test "Nebu.Matrix exposes normalize_sso_redirect_origins/1 with a @doc (ADR-020 facade for the Admin domain)" do
      assert {:module, Nebu.Matrix} = Code.ensure_loaded(Nebu.Matrix)
      assert function_exported?(Nebu.Matrix, :normalize_sso_redirect_origins, 1)
      assert is_binary(doc_of(Nebu.Matrix, :normalize_sso_redirect_origins, 1))
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC17 — boundaries
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC17 — domain boundaries (ADR-020)" do
    test "lib/nebu/matrix/** and matrix.ex name no Nebu.OAuth.<Submodule> (only the Nebu.OAuth facade functions)" do
      files = Path.wildcard(Path.join(@lib, "nebu/matrix/**/*.ex")) ++ [Path.join(@lib, "nebu/matrix.ex")]

      for f <- files do
        src = f |> File.read!() |> strip_comments()
        rel = Path.relative_to(f, @lib)
        refute src =~ ~r/Nebu\.OAuth\.[A-Z]/, "#{rel} names a Nebu.OAuth submodule: reach the OAuth domain through the Nebu.OAuth facade"
        refute src =~ ~r/alias\s+Nebu\.OAuth\.\{/, "#{rel} aliases Nebu.OAuth submodules"
        refute src =~ ~r/alias\s+Nebu\.OAuth\.[A-Z]/, "#{rel} aliases a Nebu.OAuth submodule"
      end
    end

    test "lib/nebu/web/** names no Nebu.OAuth submodule except the pre-existing Nebu.OAuth.Http forwards" do
      for f <- Path.wildcard(Path.join(@lib, "nebu/web/**/*.ex")) do
        src = f |> File.read!() |> strip_comments()
        rel = Path.relative_to(f, @lib)
        offenders = Regex.scan(~r/Nebu\.OAuth\.[A-Z]\w*/, src) |> List.flatten() |> Enum.uniq() |> Enum.reject(&(&1 == "Nebu.OAuth.Http"))
        assert offenders == [], "#{rel} names #{inspect(offenders)}"
      end
    end

    test "lib/nebu/oauth/** and oauth.ex name no Nebu.Matrix.Sso* module (the OAuth domain never reaches into the SSO flow)" do
      files = Path.wildcard(Path.join(@lib, "nebu/oauth/**/*.ex")) ++ [Path.join(@lib, "nebu/oauth.ex")]

      for f <- files do
        src = f |> File.read!() |> strip_comments()
        refute src =~ ~r/Nebu\.Matrix\.Sso\w*/, "#{Path.relative_to(f, @lib)} names a Nebu.Matrix.Sso* module"
      end
    end

    test "lib/nebu/admin/** reaches the origin validation only via Nebu.Matrix (never Nebu.Matrix.SsoRedirect)" do
      for f <- Path.wildcard(Path.join(@lib, "nebu/admin/**/*.ex")) do
        src = f |> File.read!() |> strip_comments()
        refute src =~ ~r/Nebu\.Matrix\.SsoRedirect/, "#{Path.relative_to(f, @lib)} names Nebu.Matrix.SsoRedirect"
      end

      assert code("nebu/admin/config_controller.ex") =~ "Nebu.Matrix.normalize_sso_redirect_origins"
    end

    test "Nebu.Web.ArmScript is shared infrastructure: it names no Nebu.Matrix / Nebu.OAuth module" do
      src = read_new!("nebu/web/arm_script.ex")
      refute src =~ ~r/Nebu\.(Matrix|OAuth)\b/
      assert src =~ "defmodule Nebu.Web.ArmScript"
    end

    test "the OAuth consent page now uses the shared Nebu.Web.ArmScript and keeps no private script (story consent-arming-hardening, G3-5)" do
      src = code("nebu/oauth/consent_page.ex")
      assert src =~ "Nebu.Web.ArmScript"
      refute src =~ ~r/def script\b/
    end
  end

  describe "AC17 — the three facade functions are exported with @doc" do
    test "Nebu.OAuth.trusted_redirect_url?/2, parse_form_post/1 and check_fetch_metadata/2" do
      assert {:module, Nebu.OAuth} = Code.ensure_loaded(Nebu.OAuth)

      for {fun, arity} <- [{:trusted_redirect_url?, 2}, {:parse_form_post, 1}, {:check_fetch_metadata, 2}] do
        assert function_exported?(Nebu.OAuth, fun, arity), "Nebu.OAuth.#{fun}/#{arity} missing"
        doc = doc_of(Nebu.OAuth, fun, arity)
        assert is_binary(doc) and doc != "", "Nebu.OAuth.#{fun}/#{arity} needs a @doc"
      end
    end

    test "the Matrix domain reaches the OAuth domain through exactly these facade functions (and oauth_aware?)" do
      files = Path.wildcard(Path.join(@lib, "nebu/matrix/**/*.ex")) ++ [Path.join(@lib, "nebu/matrix.ex")]

      called =
        for f <- files,
            src = f |> File.read!() |> strip_comments(),
            [_, fun] <- Regex.scan(~r/Nebu\.OAuth\.([a-z_]+[?!]?)/, src),
            uniq: true,
            do: fun

      allowed = ~w(oauth_aware? trusted_redirect_url? parse_form_post check_fetch_metadata oauth_idp_state? handle_idp_callback revoke_client)
      assert called -- allowed == [], "unexpected Nebu.OAuth facade calls from the Matrix domain: #{inspect(called -- allowed)}"
      assert "trusted_redirect_url?" in called
      assert "parse_form_post" in called
    end
  end

  describe "AC17 — compile-guarded seams, no new env variable, no COOP" do
    @seams [:sso_redirect_origins_reader, :sso_trusted_origin_check, :admin_config_sso_origins_writer, :sso_redirect_schemes_reader, :sso_store_call_timeout_ms]

    for seam <- @seams do
      test "seam #{seam} exists in lib and is compile-guarded with `if Mix.env() == :test`" do
        seam = unquote(seam)
        key = ":" <> Atom.to_string(seam)

        files =
          for f <- Path.wildcard(Path.join(@lib, "**/*.ex")),
              strip_comments(File.read!(f)) =~ key,
              do: f

        assert files != [], "no lib file references the seam #{key}"

        for f <- files do
          src = strip_comments(File.read!(f))
          assert src =~ "Mix.env() == :test", "#{Path.relative_to(f, @lib)} reads #{key} without a `Mix.env() == :test` guard"

          unguarded =
            src
            |> String.split("\n")
            |> unguarded_reads(key)

          assert unguarded == [], "#{Path.relative_to(f, @lib)} reads #{key} outside an `if Mix.env() == :test` block: #{inspect(unguarded)}"
        end
      end
    end

    test "no new NEBU_* environment variable is read by the touched or new modules" do
      baseline = ~w(NEBU_DB_URL NEBU_MATRIX_SESSION_TTL_SECONDS NEBU_OAUTH_CONFIG_CACHE_MS NEBU_OIDC_ NEBU_OIDC_CLIENT_ID NEBU_SSO_REDIRECT_SCHEMES)

      files =
        Path.wildcard(Path.join(@lib, "nebu/matrix/sso_*.ex")) ++
          Enum.map(
            ~w(nebu/web/arm_script.ex nebu/web/oidc_config.ex nebu/admin/config_controller.ex nebu/oauth/client_store.ex nebu/oauth.ex nebu/matrix.ex nebu/web/router.ex nebu/web/plugs/json_body.ex nebu/web/plugs/request_logger.ex nebu/matrix/http_public.ex),
            &Path.join(@lib, &1)
          )

      for f <- Enum.filter(files, &File.exists?/1) do
        names = File.read!(f) |> then(&Regex.scan(~r/NEBU_[A-Z0-9_]+/, &1)) |> List.flatten() |> Enum.uniq()
        assert names -- baseline == [], "#{Path.relative_to(f, @lib)} mentions new env variables #{inspect(names -- baseline)}"
      end

      for rel <- ~w(nebu/matrix/sso_redirect.ex nebu/matrix/sso_confirm.ex nebu/matrix/sso_confirm_page.ex nebu/web/arm_script.ex) do
        src = read_new!(rel)
        refute src =~ ~r/System\.(get_env|fetch_env)/, "lib/#{rel} must not read the environment (ADR-022)"
      end
    end

    test "the new modules never mention Cross-Origin-Opener-Policy (oracle M1: popup openers must survive)" do
      for rel <- ~w(nebu/matrix/sso_confirm.ex nebu/matrix/sso_confirm_page.ex nebu/web/arm_script.ex) do
        refute read_new!(rel) =~ ~r/cross-origin-opener-policy/i, "lib/#{rel} must not set COOP"
      end

      refute code("nebu/matrix/sso_login.ex") =~ ~r/cross-origin-opener-policy/i
    end

    test "no new module of this story is a GenServer or keeps node-local state (cluster safety: the store is SsoStore)" do
      for rel <- ~w(nebu/matrix/sso_redirect.ex nebu/matrix/sso_confirm.ex nebu/matrix/sso_confirm_page.ex nebu/web/arm_script.ex) do
        src = read_new!(rel)
        refute src =~ ~r/use\s+GenServer|:ets\.new|:persistent_term\.put|Agent\.start/, "lib/#{rel} must be plain functions (D1, ADR-021)"
      end
    end

    test "code review MIN-3: SsoRedirect.valid_https_host?/1 is the ONE host validator; the page keeps no second host regex" do
      assert {:module, Nebu.Matrix.SsoRedirect} = Code.ensure_loaded(Nebu.Matrix.SsoRedirect)
      assert function_exported?(Nebu.Matrix.SsoRedirect, :valid_https_host?, 1)
      src = read_new!("nebu/matrix/sso_confirm_page.ex")
      assert src =~ "valid_https_host?", "SsoConfirmPage must call SsoRedirect.valid_https_host?/1"
      refute src =~ ~r/a-z0-9/, "no host character-class regex in sso_confirm_page.ex"
    end

    test "SEC #2: every SsoStore call is wrapped (catch :exit) so a call timeout can never escape with the message" do
      src = code("nebu/matrix/sso_store.ex")
      assert src =~ ~r/catch[\s\S]{0,40}:exit/, "SsoStore must catch :exit of its GenServer.call"
      assert src =~ "sso_store_call_timeout_ms", "the call timeout seam (compile-guarded, default 5000 ms)"
    end

    test "the legacy login keeps its one classification: SsoLogin delegates to SsoRedirect.classify/1" do
      src = code("nebu/matrix/sso_login.ex")
      assert src =~ "SsoRedirect.classify"
      refute src =~ ~r/URI\.parse\(raw\)/, "redirect_url_allowed?/1 must not parse the URL a second time"
    end
  end

  # lines (as {line_no, text}) that read the seam through Application.get_env/fetch_env outside an
  # `if Mix.env() == :test do ... end` block (block = until the next line at the same indentation that starts
  # with `end` or `else`)
  defp unguarded_reads(lines, key) do
    indexed = Enum.with_index(lines, 1)

    guarded_ranges =
      for {line, i} <- indexed, line =~ ~r/^\s*if Mix\.env\(\) == :test do/ do
        indent = String.length(line) - String.length(String.trim_leading(line))

        stop =
          Enum.find_value(Enum.drop(indexed, i), length(lines), fn {l, j} ->
            ind = String.length(l) - String.length(String.trim_leading(l))
            if ind == indent and String.trim(l) in ["end", "else"], do: j
          end)

        i..stop
      end

    for {line, i} <- indexed,
        line =~ key,
        line =~ ~r/Application\.(get_env|fetch_env!?)\(/,
        not Enum.any?(guarded_ranges, &(i in &1)),
        do: {i, String.trim(line)}
  end
end
