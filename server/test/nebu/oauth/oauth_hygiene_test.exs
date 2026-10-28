defmodule Nebu.OAuth.OAuthHygieneStaticTest do
  @moduledoc """
  Static checks (no DB, no network) for story `oauth-hardening-hygiene`, AC4 (HY5): the config seams of
  `Nebu.OAuth.Config` are compile-time guarded, so a stray `Application.put_env` in a production
  release can never switch OAuth on (epic security review I-6).

  The idiom is the one of `Nebu.Matrix.OAuthSession` (`if Mix.env() == :test do defp seam(key, default),
  do: Application.get_env(:nebu_http, key, default) else defp seam(_key, default), do: default end`):
  call sites may say `seam(:oauth_config_source, nil)`, but the only `Application.get_env` /
  `fetch_env` that names these keys sits inside the `if Mix.env() == :test do` branch.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @guarded ~w(oauth_config_source oauth_config_repo oauth_config_cache_clock_fn)

  # moduledoc / doc / SQL heredocs and comment lines are not code
  defp code(text) do
    text
    |> String.replace(~r/"""[\s\S]*?"""/, "")
    |> String.split("\n")
    |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
  end

  defp env_read?(line, key),
    do: Regex.match?(~r/Application\.(get_env|fetch_env!?|fetch_env)\(\s*:nebu_http\s*,\s*:#{key}\b/, line)

  # Lines of `lines` (0-based indices) inside an `if Mix.env() == :test do` ... `else` / `end` block.
  defp guarded_indices(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce({[], nil}, fn {line, i}, {acc, open} ->
      cond do
        open == nil and Regex.match?(~r/^\s*if Mix\.env\(\) == :test do\s*$/, line) ->
          [indent] = Regex.run(~r/^(\s*)/, line, capture: :all_but_first)
          {acc, String.length(indent)}

        open != nil and Regex.match?(~r/^\s{#{open}}(else|end)\b/, line) ->
          {acc, nil}

        open != nil ->
          {[i | acc], open}

        true ->
          {acc, open}
      end
    end)
    |> elem(0)
  end

  test "AC4.1: no module but Nebu.OAuth.Config reads the guarded config seams" do
    offenders =
      for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          not String.ends_with?(file, "oauth/config.ex"),
          line <- code(File.read!(file)),
          key <- @guarded,
          env_read?(line, key) or (String.contains?(line, ":" <> key) and String.contains?(line, "Application.")),
          do: {Path.relative_to(file, @lib), key}

    assert offenders == [], "only lib/nebu/oauth/config.ex may read #{inspect(@guarded)}: #{inspect(offenders)}"
  end

  test "AC4.1: in config.ex the seam keys are read only inside an `if Mix.env() == :test do` block" do
    lines = File.read!(Path.join(@lib, "nebu/oauth/config.ex")) |> code()
    inside = MapSet.new(guarded_indices(lines))

    refute MapSet.size(inside) == 0, "config.ex has no `if Mix.env() == :test do` block"

    reads =
      for {line, i} <- Enum.with_index(lines),
          key <- @guarded,
          env_read?(line, key),
          do: {key, i}

    for {key, i} <- reads do
      assert MapSet.member?(inside, i), ":#{key} is read outside the `if Mix.env() == :test do` block (line #{i + 1} of the code-only view)"
    end

    # the idiom: the guarded branch defines the ONE env read (`Application.get_env(:nebu_http, key, default)`)
    assert Enum.any?(inside, fn i -> Enum.at(lines, i) =~ ~r/Application\.(get_env|fetch_env)\(\s*:nebu_http/ end),
           "the `if Mix.env() == :test do` block must contain the Application.get_env of the seam"
  end

  test "AC4.1 (review M8): every Application env read with a VARIABLE key inside config.ex is in the guarded block, which sits at module-body indent" do
    raw = File.read!(Path.join(@lib, "nebu/oauth/config.ex"))
    lines = code(raw)
    inside = MapSet.new(guarded_indices(lines))

    variable_reads =
      for {line, i} <- Enum.with_index(lines),
          Regex.match?(~r/Application\.(get_env|fetch_env!?|fetch_env)\(\s*:nebu_http\s*,\s*[a-z_]/, line),
          do: {line, i}

    assert variable_reads != [], "expected the seam helper's `Application.get_env(:nebu_http, key, default)`"

    for {line, i} <- variable_reads do
      assert MapSet.member?(inside, i), "a variable-key env read outside the `if Mix.env() == :test do` block: #{String.trim(line)}"
    end

    assert Regex.match?(~r/^  if Mix\.env\(\) == :test do\s*$/m, raw), "the guard must sit at module-body indent (two spaces)"
  end

  test "AC4.1: the non-test branch returns the default (`defp seam(_key, default), do: default`)" do
    text = File.read!(Path.join(@lib, "nebu/oauth/config.ex"))
    assert text =~ ~r/if Mix\.env\(\) == :test do[\s\S]*?else[\s\S]*?defp seam\(_key, default\), do: default[\s\S]*?end/
  end

  test "AC4.1: the call sites go through seam/2 (the keys appear as seam arguments, not as env reads)" do
    code = File.read!(Path.join(@lib, "nebu/oauth/config.ex")) |> code() |> Enum.join("\n")
    assert code =~ ~r/seam\(:oauth_config_source\b/
    assert code =~ ~r/seam\(:oauth_config_repo\b/
    assert code =~ ~r/seam\(:oauth_config_cache_clock_fn\b/, "the cache clock seam is compile-guarded too"
  end
end

defmodule Nebu.OAuth.OAuthHygieneTest do
  @moduledoc """
  Acceptance tests for story `oauth-hardening-hygiene`:

    * AC5 (HY6, I-10): `Nebu.Admin.OAuthRegistrationsHTML.confirm_text/3` renders the attacker-chosen client
      name with `Jason.encode!/1` (escaped quote / backslash / control characters), cut to 80 graphemes
      (`…` appended) BEFORE encoding; the verified host still comes first.
    * AC7 (HY8, I-13): `Nebu.Matrix.idp_complete_login/4` rescues exceptions AND catches exits of the
      token-exchange seam (`:matrix_sso_token_override`); only `unexpected <ExceptionModule>` or
      `unexpected exit` is logged. Pinned message: `Matrix.idp_complete_login: unexpected exit`.
    * AC14: logging law (no per-request log line from the cache / rate-limit paths, nothing of the
      client-supplied name or a raised message in a log).

  (AC6, the badge wording, is asserted in `oauth_admin_test.exs`, changed by design.)
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @html Nebu.Admin.OAuthRegistrationsHTML
  @https "https://app.example.com/cb"

  defp confirm(client, verb \\ "Approve", consequence \\ "Sure."), do: apply(@html, :confirm_text, [client, verb, consequence])

  defp client(name, uri \\ "https://evil.example.com"), do: %{client_id: "id1", client_name: name, client_uri: uri}

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — confirm text (HY6)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5 — confirm_text/3 escapes the client-chosen name" do
    test "a name that fakes the host part is JSON-escaped (quote and backslash)" do
      name = ~S|x" at evil.example (name "y|
      text = confirm(client(name))

      assert text == "Approve client at evil.example.com (name " <> Jason.encode!(name) <> ")? Sure."
      assert text =~ ~S|(name "x\" at evil.example (name \"y")?|
    end

    test "a backslash is escaped" do
      assert confirm(client(~S|a\b|)) =~ ~S|(name "a\\b")?|
    end

    test "a newline and other control characters are escaped, the text has no raw line break" do
      text = confirm(client("line1\nline2\tTab\u0001"))
      assert text =~ ~S|\n|
      assert text =~ ~S|\t|
      assert text =~ ~S|\u0001|
      refute text =~ "\n", "no raw newline may reach the native confirm() dialog"
      refute text =~ "\u0001"
    end

    test "the verified host still comes first" do
      text = confirm(client("Element (app.element.io)"))
      assert text =~ ~r/\AApprove client at evil\.example\.com \(name /
      {host_at, _} = :binary.match(text, "evil.example.com")
      {name_at, _} = :binary.match(text, "Element")
      assert host_at < name_at
    end

    test "an 81-grapheme name is cut to 80 graphemes plus an ellipsis; 80 graphemes are kept whole" do
      long = String.duplicate("a", 81)
      assert confirm(client(long)) == "Approve client at evil.example.com (name " <> Jason.encode!(String.duplicate("a", 80) <> "…") <> ")? Sure."

      exact = String.duplicate("a", 80)
      assert confirm(client(exact)) == "Approve client at evil.example.com (name " <> Jason.encode!(exact) <> ")? Sure."
      refute confirm(client(exact)) =~ "…"
    end

    test "the cut counts GRAPHEMES, not codepoints or bytes" do
      combining = String.duplicate("é", 80)
      assert String.length(combining) == 80
      refute confirm(client(combining)) =~ "…", "80 graphemes (160 codepoints) are not truncated"

      emoji = String.duplicate("\u{1F600}", 81)
      text = confirm(client(emoji))
      assert text =~ "…"
      assert text =~ String.duplicate("\u{1F600}", 80) <> "…"
    end

    test "the cut happens BEFORE the encoding: a long name of quotes is never cut inside an escape" do
      name = String.duplicate(~S|"|, 90)
      text = confirm(client(name))
      assert text == "Approve client at evil.example.com (name " <> Jason.encode!(String.duplicate(~S|"|, 80) <> "…") <> ")? Sure."
    end

    test "no-host and unnamed variants keep today's structure" do
      assert confirm(%{client_id: "id1", client_name: "N", client_uri: nil}, "Approve", "x") == ~s|Approve client "N"? x|

      assert confirm(%{client_id: "id1", client_name: nil, client_uri: "https://evil.example.com"}, "Reject", "x") ==
               ~s|Reject client at evil.example.com (name "(unnamed client id1)")? x|

      assert confirm(%{client_id: "id2", client_name: "", client_uri: nil}, "Reject", "x") == ~s|Reject client "(unnamed client id2)"? x|
    end

    test "the no-host variant escapes the name too" do
      assert confirm(%{client_id: "id1", client_name: ~S|a"b|, client_uri: nil}, "Approve", "x") == ~S|Approve client "a\"b"? x|
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 — idp_complete_login rescue / exit (HY8)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7 — a raising / exiting token exchange is :idp_unavailable" do
    setup do
      T.enable_oauth()
      T.reset_rate_limits()
      priv = T.setup_idp!()

      on_exit(fn ->
        T.clear_oauth_config()
        T.restore_rate_limits()
      end)

      {:ok, priv: priv, cid: T.oauth_client!([@https])}
    end

    test "Nebu.Matrix.idp_complete_login/4: raise => {:error, :idp_unavailable}, logs the exception module only", _ctx do
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> raise "boom-secret-text" end)

      {result, log} =
        with_log(fn -> apply(Nebu.Matrix, :idp_complete_login, [Plug.Test.conn(:get, "/"), "code", "verifier", "nonce"]) end)

      assert result == {:error, :idp_unavailable}
      assert log =~ "unexpected RuntimeError"
      refute log =~ "boom-secret-text"
    end

    test "Nebu.Matrix.idp_complete_login/4: exit => {:error, :idp_unavailable}, logs `unexpected exit` only", _ctx do
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> exit(:boom_exit_reason) end)

      {result, log} =
        with_log(fn -> apply(Nebu.Matrix, :idp_complete_login, [Plug.Test.conn(:get, "/"), "code", "verifier", "nonce"]) end)

      assert result == {:error, :idp_unavailable}
      assert log =~ "unexpected exit"
      refute log =~ "boom_exit_reason"
      refute log =~ ":boom"
    end

    test "Nebu.Matrix.idp_complete_login/4: an exit with a shutdown tuple is not a crash of the caller either", _ctx do
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> exit({:shutdown, "db-pool-gone"}) end)
      assert {:error, :idp_unavailable} = apply(Nebu.Matrix, :idp_complete_login, [Plug.Test.conn(:get, "/"), "c", "v", "n"])
    end

    test "authorize callback, raising seam => temporarily_unavailable redirect to the client; log has the type, not the message", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> raise "boom" end)

      {conn, log} = with_log(fn -> T.callback([{"code", "c"}, {"state", flow.state}], [flow.cookie]) end)

      T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(flow.pairs, "state"))
      assert log =~ "unexpected RuntimeError"
      refute log =~ "boom"
    end

    test "authorize callback, exiting seam => the same outcome, no crash, log line without the exit reason", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> exit(:boom) end)

      {conn, log} = with_log(fn -> T.callback([{"code", "c"}, {"state", flow.state}], [flow.cookie]) end)

      T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(flow.pairs, "state"))
      assert log =~ "unexpected exit"
      refute log =~ ":boom"
    end

    test "account login callback (Nebu.OAuth.Account), raising seam => its :idp_unavailable page (503)", _ctx do
      flow = T.account_start!()
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> raise "boom" end)

      {cb, log} = with_log(fn -> T.callback([{"code", "c-" <> T.rand()}, {"state", flow.state}], [flow.binding]) end)

      T.assert_account_error(cb, 503, "unavailable")
      assert log =~ "unexpected RuntimeError"
      refute log =~ "boom"
      assert T.account_cookie_from(cb) == nil, "no session cookie"
    end

    test "account login callback, exiting seam => the same page", _ctx do
      flow = T.account_start!()
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> exit(:boom) end)

      cb = T.callback([{"code", "c-" <> T.rand()}, {"state", flow.state}], [flow.binding])
      T.assert_account_error(cb, 503, "unavailable")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC14 — logging law
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14 — logging law" do
    setup do
      prior_ttl = Application.fetch_env(:nebu_http, :oauth_config_cache_ms)
      Application.put_env(:nebu_http, :oauth_config_cache_ms, 2000)
      T.clear_oauth_config()
      T.reset_rate_limits()
      original = Logger.level()
      Logger.configure(level: :debug)

      on_exit(fn ->
        Logger.configure(level: original)

        case prior_ttl do
          {:ok, v} -> Application.put_env(:nebu_http, :oauth_config_cache_ms, v)
          :error -> Application.delete_env(:nebu_http, :oauth_config_cache_ms)
        end

        if :ets.whereis(:nebu_oauth_config_cache) != :undefined, do: :ets.delete_all_objects(:nebu_oauth_config_cache)
        T.restore_rate_limits()
      end)

      :ok
    end

    test "cache hits, cache misses and a discovery 429 write no per-request log line" do
      T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => T.issuer()})
      ip = T.unique_ip()
      T.drain!("oauth_openid_configuration", ip, 600, 600)
      T.drain!("login_flows", ip, 300, 300)

      log =
        capture_log([level: :debug], fn ->
          for _ <- 1..5, do: apply(Nebu.OAuth.Config, :get, [])
          assert T.get("/.well-known/openid-configuration", ip: ip).status == 429
          assert T.login_flows(ip: ip).status == 429
          for _ <- 1..3, do: T.get_metadata()
        end)

      refute log =~ "OAuth.Config", "the cache path must not log per request, got: #{String.slice(log, 0, 300)}"
      refute log =~ "oauth_openid_configuration", "a 429 is answered, not logged"
      refute log =~ "login_flows", "a 429 is answered, not logged"
    end

    test "confirm_text/3 never raises on odd input (invalid UTF-8, huge, unexpected shapes) and logs nothing" do
      invalid = "bad-" <> <<0xFF, 0xFE, 0xC3, 0x28>> <> "-name"
      huge = String.duplicate("\u{1F600}x", 100_000)

      log =
        capture_log([level: :debug], fn ->
          assert is_binary(confirm(client(invalid)))
          assert confirm(client(invalid)) =~ "bad-"
          assert is_binary(confirm(client(huge)))
          assert String.length(confirm(client(huge))) < 300, "the cut bounds the text whatever the name length"
          assert is_binary(confirm(%{client_id: "id1", client_name: nil, client_uri: nil}))
          assert is_binary(confirm(%{client_id: "id1", client_name: "N", client_uri: "not a uri"}))
          assert is_binary(confirm(client(<<0>>)))
        end)

      refute log =~ "bad-", "nothing of the client-supplied name may be logged"
    end
  end
end
