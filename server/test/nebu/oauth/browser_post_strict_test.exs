defmodule Nebu.OAuth.BrowserPostStrictTest do
  @moduledoc """
  Unit tests (no database) for story `oauth-client-revocation` (P4), AC7.1 (decision SO2): the STRICT fetch-metadata
  level of the ONE shared copy `Nebu.OAuth.BrowserPost` (story oauth-authorize-freshness moved it there; the story's
  `Nebu.Web.FetchMetadata` is NOT created: P3 adaptation (b), extend the single copy).

  Pinned API (implemented; changing it means changing this test):

    * `BrowserPost.check(conn, issuer, strict: true) :: :ok | :refused` — everything `check/3` does today (Origin
      absent or the issuer origin, `Origin: null` only with `Sec-Fetch-Site: same-origin`) PLUS the strict level:
      each of the four headers `Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`,
      `Sec-Fetch-User: ?1` must be PRESENT exactly once with exactly that value (absent is refused: Chrome 76+,
      Firefox 90+, Safari 16.4+ send all four for a user-activated form submit). Used for
      `POST /account/cross_signing_reset/approve`.
    * `BrowserPost.check_fetch_metadata(conn, :strict | :lenient) :: :ok | {:refused, [header_name]}` — the same
      header rules WITHOUT the Origin comparison (the admin has no issuer-bound origin), for the admin controllers:
      `:strict` for approve and revoke, `:lenient` for reject and bulk removal (absent allowed, a present header must
      carry the strict value; one duplicated value refuses). The refusal lists the lower-case header NAMES that failed
      (for the value-free WARNING), never the values.
    * the lenient level is exactly today's `check/3` header behaviour (`navigation: true`): the existing callers
      (consent, account) keep their tests unchanged.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.BrowserPost

  @issuer "https://nebu.example.com"
  @strict [{"sec-fetch-site", "same-origin"}, {"sec-fetch-mode", "navigate"}, {"sec-fetch-dest", "document"}, {"sec-fetch-user", "?1"}]
  @headers ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest sec-fetch-user)

  defp conn_with(pairs), do: Enum.reduce(pairs, conn(:post, "/x"), fn {k, v}, c -> put_req_header(c, k, v) end)

  # a duplicated header: two request header entries with the same name
  defp duplicated(name, value), do: conn_with(List.keydelete(@strict, name, 0)) |> then(&%{&1 | req_headers: &1.req_headers ++ [{name, value}, {name, value}]})

  defp without(name), do: conn_with(List.keydelete(@strict, name, 0))
  defp replaced(name, value), do: conn_with(List.keyreplace(@strict, name, 0, {name, value}))

  defp meta(conn, level), do: apply(BrowserPost, :check_fetch_metadata, [conn, level])

  describe "check_fetch_metadata/2 :strict — all four headers required" do
    test "the four correct headers pass" do
      assert meta(conn_with(@strict), :strict) == :ok
    end

    test "no fetch metadata at all is refused (older browsers are locked out of the strict actions: accepted)" do
      assert {:refused, names} = meta(conn(:post, "/x"), :strict)
      assert Enum.sort(names) == Enum.sort(@headers)
    end

    for name <- @headers do
      test "#{name}: absent is refused and named" do
        assert {:refused, [unquote(name)]} = meta(without(unquote(name)), :strict)
      end

      test "#{name}: a duplicated value (even the right one twice) is refused and named" do
        value = unquote(@strict) |> List.keyfind(unquote(name), 0) |> elem(1)
        assert {:refused, [unquote(name)]} = meta(duplicated(unquote(name), value), :strict)
      end
    end

    for {name, wrong} <- [
          {"sec-fetch-site", ["cross-site", "same-site", "none", "SAME-ORIGIN", "same-origin, same-origin", ""]},
          {"sec-fetch-mode", ["cors", "no-cors", "same-origin", "websocket", "Navigate", "navigate, navigate", ""]},
          {"sec-fetch-dest", ["iframe", "empty", "frame", "embed", "object", "Document", "document, document", ""]},
          {"sec-fetch-user", ["?0", "1", "true", "?1, ?1", ""]}
        ],
        value <- wrong do
      test "#{name}: #{inspect(value)} is refused and named (value never in the result)" do
        assert {:refused, names} = meta(replaced(unquote(name), unquote(value)), :strict)
        assert names == [unquote(name)]
        if unquote(value) != "", do: refute(inspect(names) =~ unquote(value))
      end
    end

    test "several failures are all named, in no particular order" do
      conn = conn_with([{"sec-fetch-site", "cross-site"}, {"sec-fetch-mode", "cors"}, {"sec-fetch-dest", "document"}, {"sec-fetch-user", "?1"}])
      assert {:refused, names} = meta(conn, :strict)
      assert Enum.sort(names) == ["sec-fetch-mode", "sec-fetch-site"]
    end
  end

  describe "check_fetch_metadata/2 :lenient — absent allowed, a present header must be the strict value" do
    # a proxy may merge a repeated header into ONE comma-joined value: never accepted, not even at the lenient level
    for {name, merged} <- [{"sec-fetch-site", "same-origin, same-origin"}, {"sec-fetch-mode", "navigate, navigate"}, {"sec-fetch-dest", "document, document"}, {"sec-fetch-user", "?1, ?1"}] do
      test "#{name}: the comma-merged form #{inspect(merged)} is refused" do
        assert {:refused, [unquote(name)]} = meta(replaced(unquote(name), unquote(merged)), :lenient)
      end
    end

    test "no headers at all, the four correct headers, and any subset of the correct ones pass" do
      assert meta(conn(:post, "/x"), :lenient) == :ok
      assert meta(conn_with(@strict), :lenient) == :ok

      for name <- @headers, do: assert(meta(without(name), :lenient) == :ok, "#{name} absent")
    end

    for name <- @headers do
      test "#{name}: a duplicated value is refused" do
        value = unquote(@strict) |> List.keyfind(unquote(name), 0) |> elem(1)
        assert {:refused, [unquote(name)]} = meta(duplicated(unquote(name), value), :lenient)
      end
    end

    for {name, wrong} <- [
          {"sec-fetch-site", ["cross-site", "same-site", "none"]},
          {"sec-fetch-mode", ["cors", "no-cors"]},
          {"sec-fetch-dest", ["iframe", "empty"]},
          {"sec-fetch-user", ["?0"]}
        ],
        value <- wrong do
      test "#{name}: #{value} is refused (the story's reject / bulk-reject rule: cross-site, same-site, Dest iframe)" do
        assert {:refused, [unquote(name)]} = meta(replaced(unquote(name), unquote(value)), :lenient)
      end
    end

    test "a lone Sec-Fetch-Dest: iframe on an otherwise header-less request is refused" do
      assert {:refused, ["sec-fetch-dest"]} = meta(conn_with([{"sec-fetch-dest", "iframe"}]), :lenient)
    end
  end

  describe "check/3 with strict: true — Origin rules plus the strict header level" do
    test "issuer Origin (or none) + the four headers => :ok; the default (lenient) level is unchanged" do
      assert BrowserPost.check(conn_with(@strict), @issuer, strict: true) == :ok
      assert BrowserPost.check(conn_with([{"origin", @issuer} | @strict]), @issuer, strict: true) == :ok
      assert BrowserPost.check(conn(:post, "/x"), @issuer) == :ok, "lenient default: no metadata, no Origin => ok (older browsers)"
      assert BrowserPost.check(conn_with([{"origin", @issuer}]), @issuer) == :ok
    end

    test "strict refuses an absent header the lenient level accepts" do
      for name <- @headers do
        c = without(name) |> put_req_header("origin", @issuer)
        assert BrowserPost.check(c, @issuer) == :ok, "lenient accepts #{name} absent"
        assert BrowserPost.check(c, @issuer, strict: true) == :refused, "strict refuses #{name} absent"
      end
    end

    test "strict still applies the Origin rules: foreign / look-alike / several Origin headers refused, null only with same-origin" do
      for origin <- ["https://evil.example.com", "https://nebu.example.com.evil.com", "http://nebu.example.com", "https://nebu.example.com:8443"] do
        assert BrowserPost.check(conn_with([{"origin", origin} | @strict]), @issuer, strict: true) == :refused, origin
      end

      assert BrowserPost.check(conn_with([{"origin", "null"} | @strict]), @issuer, strict: true) == :ok, "null + same-origin"
      several = conn_with(@strict) |> then(&%{&1 | req_headers: &1.req_headers ++ [{"origin", @issuer}, {"origin", @issuer}]})
      assert BrowserPost.check(several, @issuer, strict: true) == :refused
    end

    test "the strict header rules of check/3 equal those of check_fetch_metadata(:strict) (one copy)" do
      variants =
        [conn_with(@strict), conn(:post, "/x")] ++
          for(name <- @headers, do: without(name)) ++
          for({name, v} <- [{"sec-fetch-site", "same-site"}, {"sec-fetch-mode", "cors"}, {"sec-fetch-dest", "iframe"}, {"sec-fetch-user", "?0"}], do: replaced(name, v))

      for c <- variants do
        expected = if meta(c, :strict) == :ok, do: :ok, else: :refused
        assert BrowserPost.check(c, @issuer, strict: true) == expected
      end
    end

    test "the existing option navigation: false still skips mode/dest/user (the account sign-out) and is independent of strict" do
      c = conn_with([{"sec-fetch-site", "same-origin"}, {"sec-fetch-mode", "cors"}])
      assert BrowserPost.check(c, @issuer, navigation: false) == :ok
      assert BrowserPost.check(c, @issuer) == :refused
    end
  end

  test "static: there is no second copy of the fetch-metadata checks (no Nebu.Web.FetchMetadata module, P3 adaptation b)" do
    refute Code.ensure_loaded?(Nebu.Web.FetchMetadata), "extend Nebu.OAuth.BrowserPost instead of adding a duplicate"
    lib = Path.expand("../../../lib", __DIR__)
    hits = for f <- Path.wildcard(Path.join(lib, "**/*.ex")), File.read!(f) =~ ~r/"sec-fetch-(mode|dest|user)"/, do: Path.relative_to(f, lib)
    assert hits == ["nebu/oauth/browser_post.ex"], "only BrowserPost reads Sec-Fetch-Mode/Dest/User, got #{inspect(hits)}"
  end
end
