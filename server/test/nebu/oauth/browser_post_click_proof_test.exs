defmodule Nebu.OAuth.BrowserPostClickProofTest do
  @moduledoc """
  Unit tests (no database) for story `safari-fetch-metadata-compat`, AC1 (decisions D1-D3): the click proof that replaces
  `Sec-Fetch-User` for browsers that never send it (Safari / WebKit) in the ONE shared copy `Nebu.OAuth.BrowserPost`.

  Pinned API:

    * `BrowserPost.check_fetch_metadata(conn, :strict, params) :: :ok | :unproven | {:refused, [header_name]}`
        - `Sec-Fetch-Site` / `-Mode` / `-Dest`: exactly once, exactly `same-origin` / `navigate` / `document` (else `{:refused, names}`)
        - `Sec-Fetch-User`: `?1` once -> fine; present in any other form -> `{:refused, ["sec-fetch-user"]}` (with or without proof)
        - `Sec-Fetch-User` absent: a WebKit `User-Agent` with `params["_click_proof"] == "1"` -> `:ok`; a WebKit `User-Agent` without
          the proof -> `:unproven`; any other engine (Chrome, Firefox, none) -> `{:refused, ["sec-fetch-user"]}` (D2)
    * `BrowserPost.check(conn, issuer, strict: true, params: params) :: :ok | :refused | :unproven` (the same rules plus the Origin
      rules; `:unproven` only at the strict level and only when everything else is fine); without `params:` nothing changes.
    * `check_fetch_metadata/2` and the lenient level keep their behaviour (`browser_post_strict_test.exs`).
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.BrowserPost
  alias Nebu.OAuth.TestSupport, as: T

  @issuer "https://nebu.example.com"
  @proof %{"_click_proof" => "1"}
  @three [{"sec-fetch-site", "same-origin"}, {"sec-fetch-mode", "navigate"}, {"sec-fetch-dest", "document"}]
  @safari T.safari_user_agent()
  @chrome T.chrome_user_agent()
  @firefox T.firefox_user_agent()

  defp conn_with(pairs), do: Enum.reduce(pairs, conn(:post, "/x"), fn {k, v}, c -> put_req_header(c, k, v) end)
  defp safari(extra \\ []), do: conn_with(@three ++ [{"user-agent", @safari}] ++ extra)
  defp three(ua), do: conn_with(@three ++ if(ua, do: [{"user-agent", ua}], else: []))

  defp strict(conn, params), do: apply(BrowserPost, :check_fetch_metadata, [conn, :strict, params])
  defp replaced(name, value, ua), do: conn_with(List.keyreplace(@three, name, 0, {name, value}) ++ [{"user-agent", ua}])

  describe "the proof is the replacement of Sec-Fetch-User for WebKit" do
    test "Safari set (three headers, no Sec-Fetch-User) + the proof => :ok" do
      assert strict(safari(), @proof) == :ok
    end

    test "Safari set without the proof => :unproven (a notice, not a refusal): absent, empty, another value, a list" do
      for params <- [%{}, %{"_click_proof" => ""}, %{"_click_proof" => "0"}, %{"_click_proof" => "true"}, %{"_click_proof" => "11"}, %{"_click_proof" => ["1"]}, %{"_click_proof" => %{"1" => "1"}}, %{"other" => "1"}] do
        assert strict(safari(), params) == :unproven, inspect(params)
      end
    end

    test "an unfetched / missing params value is no proof (never raises)" do
      assert strict(safari(), %Plug.Conn.Unfetched{aspect: :body_params}) == :unproven
      assert strict(safari(), nil) == :unproven
    end

    test "the Chrome / Firefox set (four headers) passes without any proof (the proof is not needed)" do
      for ua <- [@chrome, @firefox, @safari, nil] do
        assert strict(three(ua) |> put_req_header("sec-fetch-user", "?1"), %{}) == :ok, "UA #{inspect(ua)}"
      end
    end

    test "Sec-Fetch-User: ?1 plus the proof field is fine too (a Safari that starts sending the header)" do
      assert strict(three(@safari) |> put_req_header("sec-fetch-user", "?1"), @proof) == :ok
    end
  end

  describe "D2 — the proof counts for WebKit only: Chromium and Gecko always send Sec-Fetch-User on a user activation" do
    test "Chrome, Edge, Opera, Samsung, Firefox, no User-Agent, an empty one: absent header is refused, proof or not" do
      uas = [
        @chrome,
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 OPR/120.0.0.0",
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/27.0 Chrome/141.0.0.0 Mobile Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chromium/141.0.0.0 Safari/537.36",
        @firefox,
        "Mozilla/5.0 (X11; Linux x86_64; rv:142.0) Gecko/20100101 Firefox/142.0",
        "curl/8.7.1",
        "",
        nil
      ]

      for ua <- uas, params <- [%{}, @proof] do
        assert {:refused, ["sec-fetch-user"]} = strict(three(ua), params), "UA #{inspect(ua)} params #{inspect(params)}"
      end
    end

    test "WebKit family: Safari on macOS, iOS, iPadOS (desktop mode), Chrome / Firefox on iOS (WebKit) count as WebKit" do
      uas = [
        @safari,
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.0.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/142.0 Mobile/15E148 Safari/605.1.15"
      ]

      for ua <- uas do
        assert strict(three(ua), @proof) == :ok, "#{ua} + proof"
        assert strict(three(ua), %{}) == :unproven, "#{ua} without proof"
      end
    end

    test "each exclusion token works alone, lower case is no WebKit, a WKWebView UA without Safari/ is WebKit" do
      assert {:refused, ["sec-fetch-user"]} = strict(three("Mozilla/5.0 AppleWebKit/605.1.15 (KHTML, like Gecko) Firefox/142.0"), @proof)
      assert {:refused, ["sec-fetch-user"]} = strict(three("Mozilla/5.0 AppleWebKit/605.1.15 (KHTML, like Gecko) Chromium/141.0"), @proof)
      assert {:refused, ["sec-fetch-user"]} = strict(three("Mozilla/5.0 applewebkit/605.1.15 (KHTML, like Gecko) Version/26.0"), @proof)
      assert strict(three("Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"), @proof) == :ok
    end

    test "several User-Agent headers are never WebKit (a duplicated header is refused)" do
      c = three(nil) |> then(&%{&1 | req_headers: &1.req_headers ++ [{"user-agent", @safari}, {"user-agent", @safari}]})
      assert {:refused, ["sec-fetch-user"]} = strict(c, @proof)
    end
  end

  describe "D3 — a present Sec-Fetch-User that is not exactly ?1 is refused, proof or not, WebKit or not" do
    for value <- ["?0", "1", "true", "?1, ?1", ""], ua <- [:safari, :chrome] do
      test "Sec-Fetch-User #{inspect(value)} with #{ua} UA and the proof => refused, named, value never in the result" do
        ua = if unquote(ua) == :safari, do: @safari, else: @chrome
        assert {:refused, ["sec-fetch-user"]} = names = strict(three(ua) |> put_req_header("sec-fetch-user", unquote(value)), @proof)
        if unquote(value) != "", do: refute(inspect(names) =~ unquote(value))
      end
    end

    test "a duplicated Sec-Fetch-User (even ?1 twice) is refused with the proof" do
      c = safari() |> then(&%{&1 | req_headers: &1.req_headers ++ [{"sec-fetch-user", "?1"}, {"sec-fetch-user", "?1"}]})
      assert {:refused, ["sec-fetch-user"]} = strict(c, @proof)
    end
  end

  describe "the other three headers stay strict, whatever the proof" do
    for {name, wrong} <- [
          {"sec-fetch-site", ["cross-site", "same-site", "none", "", "same-origin, same-origin"]},
          {"sec-fetch-mode", ["cors", "no-cors", "same-origin", "websocket", "", "navigate, navigate"]},
          {"sec-fetch-dest", ["iframe", "empty", "frame", "embed", "", "document, document"]}
        ],
        value <- wrong do
      test "Safari + proof + #{name}: #{inspect(value)} (fetch(), iframe, cross-origin) => refused and named" do
        assert {:refused, [unquote(name)]} = strict(replaced(unquote(name), unquote(value), @safari), @proof)
        assert {:refused, [unquote(name)]} = strict(replaced(unquote(name), unquote(value), @safari), %{})
      end
    end

    for name <- ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest) do
      test "Safari + proof + #{name} absent (a proxy strips it / an old browser) => refused, named; and absent twice-missing is never :unproven" do
        c = conn_with(List.keydelete(@three, unquote(name), 0) ++ [{"user-agent", @safari}])
        assert {:refused, [unquote(name)]} = strict(c, @proof)
        assert {:refused, [unquote(name)]} = strict(c, %{})
      end
    end

    test "no fetch metadata at all (Safari before 16.4, a stripping proxy) is refused: the three headers are named, the proof does not help" do
      c = conn(:post, "/x") |> put_req_header("user-agent", @safari)
      assert {:refused, names} = strict(c, @proof)
      assert Enum.sort(names) == ["sec-fetch-dest", "sec-fetch-mode", "sec-fetch-site"]
    end

    test "a failure of the three headers wins over the missing proof: a fetch() of a WebKit script never gets the friendly notice" do
      c = replaced("sec-fetch-mode", "cors", @safari) |> put_req_header("sec-fetch-dest", "empty")
      assert {:refused, names} = strict(c, %{})
      assert Enum.sort(names) == ["sec-fetch-dest", "sec-fetch-mode"]
    end
  end

  describe "the existing arities do not change" do
    test "check_fetch_metadata/2 :strict still refuses a missing Sec-Fetch-User, also for a Safari User-Agent (no params, no proof logic)" do
      assert {:refused, ["sec-fetch-user"]} = BrowserPost.check_fetch_metadata(safari(), :strict)
    end

    test "the :lenient level accepts the Safari set, with or without proof" do
      assert BrowserPost.check_fetch_metadata(safari(), :lenient) == :ok
      assert apply(BrowserPost, :check_fetch_metadata, [safari(), :lenient, @proof]) == :ok
    end
  end

  describe "check/3 (Origin rules + fetch metadata) with params:" do
    defp check(conn, params), do: BrowserPost.check(conn, @issuer, strict: true, params: params)

    test "Safari set + proof + issuer Origin => :ok; without proof => :unproven; without params: option => :refused as before" do
      c = safari([{"origin", @issuer}])
      assert check(c, @proof) == :ok
      assert check(c, %{}) == :unproven
      assert BrowserPost.check(c, @issuer, strict: true) == :refused
    end

    test "the Origin rules still win: a foreign Origin is :refused (never :unproven), Origin: null needs same-origin" do
      assert check(safari([{"origin", "https://evil.example.com"}]), %{}) == :refused
      assert check(safari([{"origin", "https://evil.example.com"}]), @proof) == :refused
      assert check(safari([{"origin", "null"}]), @proof) == :ok
      several = safari() |> then(&%{&1 | req_headers: &1.req_headers ++ [{"origin", @issuer}, {"origin", @issuer}]})
      assert check(several, @proof) == :refused
    end

    test "a header failure is :refused (never :unproven); a non-WebKit engine without Sec-Fetch-User is :refused" do
      assert check(replaced("sec-fetch-mode", "cors", @safari), %{}) == :refused
      assert check(three(@chrome), @proof) == :refused
      assert check(three(@chrome) |> put_req_header("sec-fetch-user", "?1"), %{}) == :ok
    end

    test "the lenient default with params: is unchanged (Safari set => :ok, no proof logic)" do
      assert BrowserPost.check(safari(), @issuer, params: %{}) == :ok
      assert BrowserPost.check(safari(), @issuer) == :ok
    end

    test "navigation: false (account sign-out) is unaffected" do
      assert BrowserPost.check(conn_with([{"sec-fetch-site", "same-origin"}, {"sec-fetch-mode", "cors"}]), @issuer, navigation: false, params: %{}) == :ok
    end
  end

  test "the facade Nebu.OAuth delegates the new arity" do
    assert apply(Nebu.OAuth, :check_fetch_metadata, [safari(), :strict, @proof]) == :ok
    assert apply(Nebu.OAuth, :check_fetch_metadata, [safari(), :strict, %{}]) == :unproven
  end

  test "the proof parameter name is the one of the page script and of the forms" do
    assert apply(BrowserPost, :click_proof_param, []) == "_click_proof"
    assert T.click_proof_param() == "_click_proof"
  end

  test "static: only BrowserPost reads Sec-Fetch-Mode/Dest/User and the User-Agent for the proof (no second copy)" do
    lib = Path.expand("../../../lib", __DIR__)
    hits = for f <- Path.wildcard(Path.join(lib, "**/*.ex")), File.read!(f) =~ ~r/"user-agent"/ and File.read!(f) =~ ~r/AppleWebKit/, do: Path.relative_to(f, lib)
    assert hits == ["nebu/oauth/browser_post.ex"], "got #{inspect(hits)}"
  end
end
