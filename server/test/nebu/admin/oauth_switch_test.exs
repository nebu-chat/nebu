defmodule Nebu.Admin.OAuthSwitchTest do
  @moduledoc """
  Story `admin-oauth-switch`, AC3 / AC5 / AC7 (decisions D2, D3, D5, D6, D9): the pure parts of the OAuth switch on
  `/admin/config`. `Nebu.Admin.OAuthSwitch.validate/2` turns the submitted form params and the stored state into a change
  or per-field errors (no I/O, no database), `status/2` derives the non-blocking precondition list from the stored config
  and an `env` map the caller reads from the running node.

  Contract pinned here:

    * `stored(config)` — `config` is the `[{key, value}]` list of the page; `%{enabled: boolean, issuer: binary}`
      (`enabled` only for the exact text `"true"`, `issuer` trimmed, `""` when absent).
    * `validate(params, stored)` — `{:ok, %{enabled:, issuer:, enabled_before:, issuer_before:, changed?:, enabling?:}}` or
      `{:error, %{optional(:enabled | :issuer | :ack) => message}}`. The issuer is validated by
      `Nebu.OAuth.normalize_issuer/1` (the runtime function) plus the form-only rules (no whitespace / control character,
      at most 255 bytes); the stored form is the normalized one.
    * `status(config, env)` — a list of `%{id:, level: :ok | :attention | :note, text:}`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Admin.OAuthSwitch

  @off %{enabled: false, issuer: ""}
  @on %{enabled: true, issuer: "https://chat.example.com"}

  defp params(enabled, issuer, ack \\ nil) do
    base = %{"oauth_enabled" => enabled, "oauth_issuer_url" => issuer}
    if ack, do: Map.put(base, "oauth_activation_ack", ack), else: base
  end

  describe "stored/1" do
    test "reads the two keys; everything but the exact text true is off; an absent issuer is the empty string" do
      assert OAuthSwitch.stored([]) == @off
      assert OAuthSwitch.stored([{"oauth_enabled", "true"}, {"oauth_issuer_url", " https://chat.example.com "}]) == @on
      assert %{enabled: false} = OAuthSwitch.stored([{"oauth_enabled", "TRUE"}])
      assert %{enabled: false} = OAuthSwitch.stored([{"oauth_enabled", "1"}])
      assert %{enabled: false} = OAuthSwitch.stored([{"oauth_enabled", "false"}])
    end
  end

  describe "AC3 — validate/2: the issuer is validated by the runtime function" do
    test "the normalized issuer is returned (trimmed, one trailing slash stripped)" do
      assert {:ok, %{issuer: "https://chat.example.com"}} = OAuthSwitch.validate(params("false", "  https://chat.example.com/  ", "true"), @off)
      assert {:ok, %{issuer: "https://chat.example.com:8448"}} = OAuthSwitch.validate(params("false", "https://chat.example.com:8448", "true"), @off)
    end

    for {label, issuer} <- [
          {"http", "http://chat.example.com"},
          {"a path", "https://chat.example.com/matrix"},
          {"two trailing slashes", "https://chat.example.com//"},
          {"a query", "https://chat.example.com?x=1"},
          {"a fragment", "https://chat.example.com#x"},
          {"userinfo", "https://user@chat.example.com"},
          {"no host", "https://"},
          {"no scheme", "chat.example.com"},
          {"a scheme-relative URL", "//chat.example.com"},
          {"javascript", "javascript:alert(1)"},
          {"an inner space", "https://chat example.com"},
          {"a tab inside", "https://chat.example.com\t.evil.com"},
          {"a newline inside", "https://chat.example.com\nx"},
          {"a NUL byte", "https://chat.example.com\0"},
          {"more than 255 bytes", "https://" <> String.duplicate("a", 248)},
          {"an empty port", "https://chat.example.com:"},
          {"a non-numeric port", "https://chat.example.com:abc"},
          {"port 0", "https://chat.example.com:0"},
          {"a port above 65535", "https://chat.example.com:65536"},
          {"a backslash before an @", "https://chat.example.com\\@evil.example"},
          {"backslashes instead of slashes", "https:\\\\chat.example.com"},
          {"a percent escape in the host", "https://chat.example.com%2Fx"},
          {"an IDN host (punycode is required)", "https://chät.example.com"},
          {"a leading dash in the host", "https://-chat.example.com"},
          {"an empty IPv6 literal", "https://[]"}
        ] do
      test "#{label} is refused while the switch is off too (a junk value is never persisted)" do
        assert {:error, %{issuer: message}} = OAuthSwitch.validate(params("false", unquote(issuer)), @off)
        assert is_binary(message) and message != ""
      end

      test "#{label} is refused while the switch is on" do
        assert {:error, %{issuer: _}} = OAuthSwitch.validate(params("true", unquote(issuer), "true"), @off)
      end
    end

    test "invalid UTF-8 is a validation error, never an exception (validate/2 is a pure function that promises a result)" do
      assert {:error, %{issuer: _}} = OAuthSwitch.validate(params("false", <<0xFF, 0x41>>), @off)
      assert {:error, %{issuer: _}} = OAuthSwitch.validate(params("true", "https://a" <> <<0xC3>>, "true"), @off)
    end

    test "the 255 byte limit is inclusive: exactly 255 bytes is valid" do
      issuer = "https://" <> String.duplicate("a", 247)
      assert byte_size(issuer) == 255
      assert {:ok, %{issuer: ^issuer}} = OAuthSwitch.validate(params("false", issuer, "true"), @off)
    end

    test "the host case is kept as typed (the runtime function does not normalize it); a case-only edit is a change, saved with the typed case" do
      assert {:ok, %{issuer: "https://CHAT.example.com", changed?: true}} = OAuthSwitch.validate(params("false", "https://CHAT.example.com", "true"), %{enabled: false, issuer: "https://chat.example.com"})
    end

    test "local and literal hosts are allowed (a test stack, an IP deployment); a bracketed IPv6 literal and a valid port too" do
      for issuer <- ["https://localhost", "https://127.0.0.1:8448", "https://[::1]:8448", "https://nebu.localtest.me:7443", "https://chat.example.com:443"] do
        assert {:ok, _} = OAuthSwitch.validate(params("false", issuer, "true"), @off), issuer
      end
    end

    test "leading and trailing whitespace is trimmed, never an error" do
      assert {:ok, %{issuer: "https://chat.example.com"}} = OAuthSwitch.validate(params("false", "\t https://chat.example.com \n", "true"), @off)
    end

    test "every case the runtime function refuses is refused here as well (same function, never looser)" do
      for issuer <- ["http://a.example", "https://a.example/x", "https://a.example?q", "https://u@a.example", "https://", "ftp://a.example"] do
        assert Nebu.OAuth.normalize_issuer(issuer) == :error
        assert {:error, %{issuer: _}} = OAuthSwitch.validate(params("false", issuer), @off)
      end
    end

    test "an empty issuer is valid only while the switch is off (stored as the empty string)" do
      assert {:ok, %{enabled: false, issuer: ""}} = OAuthSwitch.validate(params("false", "", "true"), @off)
      assert {:ok, %{enabled: false, issuer: ""}} = OAuthSwitch.validate(params("false", "   ", "true"), @off)
      assert {:ok, %{enabled: false, issuer: ""}} = OAuthSwitch.validate(%{"oauth_enabled" => "false"}, @off)
    end

    test "enabling without a valid issuer is refused with a clear message on the issuer field" do
      for issuer <- ["", "   ", "http://chat.example.com"] do
        assert {:error, %{issuer: message}} = OAuthSwitch.validate(params("true", issuer, "true"), @off)
        assert message =~ ~r/switched on without a valid https issuer/i, "#{inspect(issuer)}: #{message}"
      end

      assert {:error, %{issuer: _}} = OAuthSwitch.validate(%{"oauth_enabled" => "true", "oauth_activation_ack" => "true"}, @off)
    end
  end

  describe "AC3 — validate/2: oauth_enabled accepts only true / false" do
    for bad <- ["", "yes", "on", "1", "TRUE", "True", "false ", " true", nil] do
      test "#{inspect(bad)} is a validation error, never a silent off" do
        p = %{"oauth_enabled" => unquote(bad), "oauth_issuer_url" => "https://chat.example.com", "oauth_activation_ack" => "true"}
        p = if unquote(bad) == nil, do: Map.delete(p, "oauth_enabled"), else: p
        assert {:error, %{enabled: message}} = OAuthSwitch.validate(p, @on)
        assert is_binary(message)
      end
    end

    test "a list or a map value (a parameter pollution shape) is a validation error" do
      assert {:error, %{enabled: _}} = OAuthSwitch.validate(%{"oauth_enabled" => ["false", "true"], "oauth_issuer_url" => ""}, @off)
      assert {:error, %{enabled: _}} = OAuthSwitch.validate(%{"oauth_enabled" => %{"a" => "true"}, "oauth_issuer_url" => ""}, @off)
      assert {:error, %{issuer: _}} = OAuthSwitch.validate(%{"oauth_enabled" => "false", "oauth_issuer_url" => ["https://a.example"]}, @off)
    end
  end

  describe "D5 — the activation acknowledgement" do
    test "turning the switch on needs the acknowledgement (only the exact value true counts)" do
      for ack <- [nil, "", "false", "1", "on", "yes"] do
        assert {:error, %{ack: message}} = OAuthSwitch.validate(params("true", "https://chat.example.com", ack), @off), inspect(ack)
        assert message =~ ~r/checklist/i
      end

      assert {:ok, %{enabled: true, enabling?: true, changed?: true}} = OAuthSwitch.validate(params("true", "https://chat.example.com", "true"), @off)
    end

    test "changing the issuer while the switch stays on needs it too" do
      assert {:error, %{ack: _}} = OAuthSwitch.validate(params("true", "https://other.example.com"), @on)
      assert {:ok, %{changed?: true}} = OAuthSwitch.validate(params("true", "https://other.example.com", "true"), @on)
    end

    test "switching OFF needs no acknowledgement" do
      assert {:ok, %{enabled: false, enabling?: false, changed?: true, enabled_before: true}} = OAuthSwitch.validate(params("false", "https://chat.example.com"), @on)
    end

    test "an unchanged state (D6) needs none and reports changed?: false, enabling?: false" do
      assert {:ok, %{changed?: false, enabling?: false}} = OAuthSwitch.validate(params("true", "https://chat.example.com/"), @on)
      assert {:ok, %{changed?: false}} = OAuthSwitch.validate(params("false", "", "true"), @off)
    end

    test "stored ON with an issuer the runtime reads as off: saving a valid issuer needs the acknowledgement (the issuer changes, OAuth was not offered)" do
      broken = %{enabled: true, issuer: "http://chat.example.com"}
      assert {:error, %{ack: _}} = OAuthSwitch.validate(params("true", "https://chat.example.com"), broken)
      assert {:ok, %{changed?: true}} = OAuthSwitch.validate(params("true", "https://chat.example.com", "true"), broken)
    end

    test "all errors are reported together (issuer and acknowledgement), so one round trip shows everything" do
      assert {:error, %{issuer: _, ack: _}} = OAuthSwitch.validate(params("true", "http://x.example"), @off)
    end
  end

  describe "SEC M-1 — an issuer set or changed while the switch stays OFF widens the legacy-SSO trust: it needs the acknowledgement too" do
    test "setting an issuer while off needs it; with it the change is accepted" do
      assert {:error, %{ack: message}} = OAuthSwitch.validate(params("false", "https://chat.example.com"), @off)
      assert message =~ ~r/legacy SSO/i
      assert {:ok, %{changed?: true, enabled: false}} = OAuthSwitch.validate(params("false", "https://chat.example.com", "true"), @off)
    end

    test "changing the issuer while off, or while switching off, needs it" do
      stored = %{enabled: false, issuer: "https://old.example.com"}
      assert {:error, %{ack: _}} = OAuthSwitch.validate(params("false", "https://new.example.com"), stored)
      assert {:error, %{ack: _}} = OAuthSwitch.validate(params("false", "https://other.example.com"), @on)
    end

    test "clearing the issuer, switching off with the issuer unchanged and an unchanged state need none" do
      assert {:ok, %{changed?: true, issuer: ""}} = OAuthSwitch.validate(params("false", ""), %{enabled: false, issuer: "https://old.example.com"})
      assert {:ok, %{changed?: true, enabled: false}} = OAuthSwitch.validate(params("false", "https://chat.example.com/"), @on)
      assert {:ok, %{changed?: false}} = OAuthSwitch.validate(params("false", "https://old.example.com"), %{enabled: false, issuer: "https://old.example.com"})
    end

    test "the normalized stored issuer is reported for the caller's audit decision" do
      assert {:ok, %{issuer_before_normalized: "https://chat.example.com", issuer: "https://chat.example.com"}} =
               OAuthSwitch.validate(params("false", "https://chat.example.com"), %{enabled: true, issuer: "https://chat.example.com/"})
    end
  end

  describe "validate/2 — the before values and the change flags" do
    test "the before values come from the stored state" do
      assert {:ok, %{enabled_before: true, issuer_before: "https://chat.example.com", enabled: false, issuer: "https://other.example.com"}} =
               OAuthSwitch.validate(params("false", "https://other.example.com", "true"), @on)
    end

    test "clearing the issuer while off is a change when one was stored" do
      assert {:ok, %{changed?: true, issuer: ""}} = OAuthSwitch.validate(params("false", ""), %{enabled: false, issuer: "https://chat.example.com"})
    end
  end

  # ─── status ────────────────────────────────────────────────────────────────

  defp env(overrides \\ %{}) do
    Map.merge(
      %{
        trusted_proxy_cidrs: ["10.0.0.2/32"],
        server_name: "chat.example.com",
        admin_session_secure: true,
        reauth_allow_missing: false,
        node_answers: false,
        cache_ms: 2000
      },
      overrides
    )
  end

  defp by_id(items, id), do: Enum.find(items, &(&1.id == id))

  describe "AC5 — status/2" do
    test "every item has an id, a level and a non-empty text" do
      for item <- OAuthSwitch.status([], env()) do
        assert item.level in [:ok, :attention, :note]
        assert is_atom(item.id)
        assert is_binary(item.text) and item.text != ""
      end
    end

    test "the stored switch and issuer are always reported" do
      off = by_id(OAuthSwitch.status([], env()), :switch)
      assert off.text =~ ~r/\boff\b/i
      refute off.text =~ ~r/\bon\b/i

      on = by_id(OAuthSwitch.status([{"oauth_enabled", "true"}, {"oauth_issuer_url", "https://chat.example.com"}], env(%{node_answers: true})), :switch)
      assert on.text =~ ~r/\bon\b/i
      refute on.text =~ ~r/\boff\b/i
      assert on.text =~ "https://chat.example.com"
    end

    test "an empty trusted-proxy list is an attention item that names G3-2 and the direct-connection case" do
      item = by_id(OAuthSwitch.status([], env(%{trusted_proxy_cidrs: []})), :proxy)
      assert item.level == :attention
      assert item.text =~ "NEBU_TRUSTED_PROXY_CIDRS"
      assert item.text =~ ~r/global/i
      assert item.text =~ ~r/directly/i
    end

    test "a configured list is reported as a note and never claims the load balancer was verified" do
      item = by_id(OAuthSwitch.status([], env(%{trusted_proxy_cidrs: ["10.0.0.2/32", "10.0.0.3/32"]})), :proxy)
      assert item.level == :note, "a configured list proves nothing the server can see: never OK"
      assert item.text =~ "2"
      assert item.text =~ ~r/cannot verify|not verified|cannot see/i
    end

    test "stored ON with an invalid issuer: an attention item that says OAuth is NOT offered (fail closed), never a propagation note" do
      cfg = [{"oauth_enabled", "true"}, {"oauth_issuer_url", "http://chat.example.com"}]
      item = by_id(OAuthSwitch.status(cfg, env(%{node_answers: false})), :node)
      assert item.level == :attention
      assert item.text =~ ~r/does NOT offer OAuth|not offered/i
      refute item.text =~ ~r/within \d+ seconds/
    end

    test "this node: answers 200 with the switch on is ok; the other three combinations explain the propagation" do
      on = [{"oauth_enabled", "true"}, {"oauth_issuer_url", "https://chat.example.com"}]
      assert %{level: :ok, text: t1} = by_id(OAuthSwitch.status(on, env(%{node_answers: true})), :node)
      assert t1 =~ "200"

      assert %{level: :note, text: t2} = by_id(OAuthSwitch.status(on, env(%{node_answers: false})), :node)
      assert t2 =~ ~r/2 seconds|within 2 s/i

      assert %{level: :note} = by_id(OAuthSwitch.status([], env(%{node_answers: true})), :node)
      assert %{level: :ok, text: t3} = by_id(OAuthSwitch.status([], env(%{node_answers: false})), :node)
      assert t3 =~ "404"
    end

    test "the propagation note follows the configured cache TTL (0 = immediately)" do
      on = [{"oauth_enabled", "true"}, {"oauth_issuer_url", "https://chat.example.com"}]
      assert by_id(OAuthSwitch.status(on, env(%{node_answers: false, cache_ms: 5000})), :node).text =~ ~r/5 seconds|within 5 s/i
      assert by_id(OAuthSwitch.status(on, env(%{node_answers: false, cache_ms: 0})), :node).text =~ ~r/immediately|no delay/i
    end

    test "issuer host != NEBU_SERVER_NAME is an attention item that mentions .well-known delegation; equal is ok; no issuer = no item" do
      cfg = fn issuer -> [{"oauth_issuer_url", issuer}] end
      assert %{level: :attention, text: t} = by_id(OAuthSwitch.status(cfg.("https://other.example.com"), env()), :issuer_host)
      assert t =~ "chat.example.com" and t =~ "other.example.com" and t =~ ~r/well-known/i

      assert %{level: :ok} = by_id(OAuthSwitch.status(cfg.("https://CHAT.example.com/"), env()), :issuer_host)
      assert %{level: :ok} = by_id(OAuthSwitch.status(cfg.("https://chat.example.com:8448"), env(%{server_name: "chat.example.com:8448"})), :issuer_host)
      assert %{level: :attention} = by_id(OAuthSwitch.status(cfg.("https://chat.example.com:8448"), env()), :issuer_host)
      assert by_id(OAuthSwitch.status([], env()), :issuer_host) == nil
      assert by_id(OAuthSwitch.status(cfg.("not a url"), env()), :issuer_host) == nil
    end

    test "matrix_oidc_refresh_mode online with per_refresh (the default) is an attention item; offline, or revalidation off, is a note" do
      assert %{level: :attention, text: t} = by_id(OAuthSwitch.status([{"matrix_oidc_refresh_mode", "online"}], env()), :refresh_mode)
      assert t =~ "matrix_oidc_refresh_mode" and t =~ ~r/offline/
      assert t =~ ~r/logins are refused/i

      assert %{level: :note} = by_id(OAuthSwitch.status([{"matrix_oidc_refresh_mode", "offline"}], env()), :refresh_mode)
      assert %{level: :note} = by_id(OAuthSwitch.status([], env()), :refresh_mode), "absent = the documented default offline"
      assert %{level: :note} = by_id(OAuthSwitch.status([{"matrix_oidc_refresh_mode", "online"}, {"oauth_idp_revalidation", "off"}], env()), :refresh_mode)
      assert %{level: :attention} = by_id(OAuthSwitch.status([{"matrix_oidc_refresh_mode", "online"}, {"oauth_idp_revalidation", "junk"}], env()), :refresh_mode), "unknown values behave as per_refresh"
    end

    test "an insecure admin session and the re-auth opt-out are reported only when set" do
      assert %{level: :attention, text: t} = by_id(OAuthSwitch.status([], env(%{admin_session_secure: false})), :secure)
      assert t =~ ~r/https/i
      assert by_id(OAuthSwitch.status([], env()), :secure) == nil

      assert %{level: :note, text: t2} = by_id(OAuthSwitch.status([], env(%{reauth_allow_missing: true})), :reauth_optout)
      assert t2 =~ "NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME"
      assert by_id(OAuthSwitch.status([], env()), :reauth_optout) == nil
    end

    test "the propagation wording is ONE function (page help, flash and status list)" do
      assert OAuthSwitch.propagation_text(0) == "immediately"
      assert OAuthSwitch.propagation_text(2000) == "within 2 seconds"
      assert OAuthSwitch.propagation_text(1500) == "within 2 seconds"
      assert OAuthSwitch.propagation_text(5000) == "within 5 seconds"
    end

    test "no item ever claims that a precondition the server cannot see is fulfilled" do
      all = OAuthSwitch.status([{"oauth_enabled", "true"}, {"oauth_issuer_url", "https://chat.example.com"}], env(%{node_answers: true}))
      joined = Enum.map_join(all, " ", & &1.text)
      refute joined =~ ~r/load balancer (is|has been) (verified|correct)/i
      refute joined =~ ~r/ready to (switch|activate)|all (checks|preconditions) (passed|met)/i
    end
  end

  describe "current_env/0 reads the running node" do
    test "returns the keys status/2 needs, of the right types" do
      env = OAuthSwitch.current_env()

      assert is_list(env.trusted_proxy_cidrs)
      assert is_binary(env.server_name)
      assert is_boolean(env.admin_session_secure)
      assert is_boolean(env.reauth_allow_missing)
      assert is_boolean(env.node_answers)
      assert is_integer(env.cache_ms) and env.cache_ms >= 0
    end

    test "node_answers follows the live predicate (Nebu.OAuth.oauth_aware?/0)" do
      Nebu.OAuth.TestSupport.enable_oauth()
      on_exit(&Nebu.OAuth.TestSupport.clear_oauth_config/0)
      assert OAuthSwitch.current_env().node_answers == true
      Nebu.OAuth.TestSupport.disable_oauth()
      assert OAuthSwitch.current_env().node_answers == false
    end
  end
end
