defmodule Nebu.OAuth.OAuthAccountPagesTest do
  @moduledoc """
  Unit tests for story `oauth-account-management` (story 6 of epic oauth-broker), A20 /
  Must #33 (no DB): the standalone renderer `Nebu.OAuth.AccountPages`.

  Pinned API (via `apply/3`): `AccountPages.error_codes/0 :: [String.t()]` (at least the A20 codes)
  and `AccountPages.send_error(conn, status, code) :: Plug.Conn.t()` (sends the page). Every error
  page: `lang="en"`, charset + viewport meta, a code-specific `<title>`, exactly one `<main
  data-page="account-error" data-error=code>`, exactly one `<h1>`, no `<script>`, no `on*=` handler,
  no external URL (`http(s)://`, `//`), no `<img>`; headers: `text/html; charset=utf-8`, the A20 CSP
  whose `style-src` hash equals the SHA-256 of the ONE inline `<style>` block, `X-Frame-Options:
  DENY`, `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy: same-origin` (review cycle 1 M1: `no-referrer` makes browsers send `Origin: null` for the page's own form POSTs), no CORS.
  Structure of the action pages is covered through HTTP in `oauth_account_test.exs`.

  """
  use ExUnit.Case, async: true

  @mod Nebu.OAuth.AccountPages
  @a20_codes ~w(unavailable rate_limited method_not_allowed not_found invalid_request invalid_state forbidden
                no_account deactivated reauth_failed access_denied server_error)

  defp render(code, status \\ 400), do: apply(@mod, :send_error, [Plug.Test.conn(:get, "/account"), status, code])
  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "error_codes/0 covers every A20 code" do
    assert {:module, _} = Code.ensure_loaded(@mod)
    codes = apply(@mod, :error_codes, [])
    for c <- @a20_codes, do: assert(c in codes, "missing error page #{c}")
  end

  for code <- @a20_codes do
    test "error page #{code}: structure, accessibility hooks, no script / handler / external resource" do
      conn = render(unquote(code))
      body = conn.resp_body
      assert body =~ ~r/<html[^>]*lang="en"/
      assert body =~ ~r/<meta[^>]*charset/i
      assert body =~ ~r/<meta[^>]*name="viewport"/
      assert length(Regex.scan(~r/<main[\s>]/, body)) == 1
      assert body =~ ~s(data-page="account-error") and body =~ ~s(data-error="#{unquote(code)}")
      assert length(Regex.scan(~r/<h1[\s>]/, body)) == 1
      assert [_, title] = Regex.run(~r/<title>([^<]+)<\/title>/, body)
      assert String.length(title) > 5
      refute body =~ ~r/<script/i
      refute body =~ ~r/\son[a-z]+\s*=/i, "no inline event handler"
      refute body =~ ~r/(src|href)="(https?:)?\/\//i, "no external resource"
      refute body =~ ~r/<img/i
    end

    test "error page #{code}: headers and the CSP hash of the one inline style" do
      conn = render(unquote(code))
      assert header(conn, "content-type") =~ ~r{^text/html;\s*charset=utf-8}i
      assert header(conn, "x-frame-options") == "DENY"
      assert header(conn, "cache-control") =~ "no-store"
      assert header(conn, "pragma") == "no-cache"
      assert header(conn, "referrer-policy") == "same-origin"
      refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)

      csp = header(conn, "content-security-policy")
      assert csp =~ ~r/^default-src 'none'; /
      for part <- ["img-src 'none'", "form-action 'self'", "base-uri 'none'", "frame-ancestors 'none'"], do: assert(csp =~ part)
      [_, hash] = Regex.run(~r/style-src 'sha256-([^']+)'/, csp)
      styles = Regex.scan(~r/<style>(.*?)<\/style>/s, conn.resp_body) |> Enum.map(&List.last/1)
      assert [css] = styles, "exactly one inline style block"
      assert hash == Base.encode64(:crypto.hash(:sha256, css)), "the CSP hash equals the CSS actually inlined"
    end
  end

  test "titles differ per error code" do
    titles = for c <- @a20_codes, do: render(c).resp_body |> then(&(Regex.run(~r/<title>([^<]+)<\/title>/, &1) |> List.last()))
    assert titles |> Enum.uniq() |> length() == length(titles)
  end
end
