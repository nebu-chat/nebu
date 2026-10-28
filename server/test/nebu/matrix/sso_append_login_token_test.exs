defmodule Nebu.Matrix.SsoAppendLoginTokenTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC1.6 / D20 (oracle m3): the
  Matrix spec (CS API v1.18, "Handling the callback from the Authentication server") says existing `loginToken`
  parameters of the `redirectUrl` "should be removed before adding the new one". `SsoLogin.append_login_token/2`
  therefore drops EVERY parameter named exactly `loginToken` (after percent-decoding the name) from the query of
  the base (before the first `#`) and from the FRAGMENT's own `?` query part (Element Web's hash routing), then
  appends the new one exactly as today (fragment aware, `?` or `&`). Every other parameter, its order and its
  encoding stay byte-identical; URLs without a `loginToken` parameter give the pre-story output.

  Pure function, no DB.
  """
  use ExUnit.Case, async: true

  alias Nebu.Matrix.SsoLogin

  @new "NEW"

  # {input, expected}: the rows of AC1.6 plus the D20 corner cases
  @rows [
    # AC1.6 verbatim
    {"https://a.ex/cb?loginToken=old", "https://a.ex/cb?loginToken=NEW"},
    {"https://a.ex/cb?x=1&loginToken=old&y=2", "https://a.ex/cb?x=1&y=2&loginToken=NEW"},
    {"https://a.ex/cb?loginToken=a&loginToken=b", "https://a.ex/cb?loginToken=NEW"},
    {"https://a.ex/#/login?loginToken=old", "https://a.ex/?loginToken=NEW#/login"},
    {"https://a.ex/cb?logintoken=keep", "https://a.ex/cb?logintoken=keep&loginToken=NEW"},
    {"https://a.ex/cb?xloginToken=keep", "https://a.ex/cb?xloginToken=keep&loginToken=NEW"},
    # regression rows: byte-identical to the pre-story output
    {"http://localhost:7070/#/home", "http://localhost:7070/?loginToken=NEW#/home"},
    {"http://localhost:7070", "http://localhost:7070?loginToken=NEW"},
    {"http://localhost:7070/", "http://localhost:7070/?loginToken=NEW"},
    {"element://vector/webapp/?element-desktop-ssoid=abc#/login", "element://vector/webapp/?element-desktop-ssoid=abc&loginToken=NEW#/login"},
    {"https://a.ex/cb?x=1", "https://a.ex/cb?x=1&loginToken=NEW"},
    {"https://a.ex/cb#frag", "https://a.ex/cb?loginToken=NEW#frag"},
    {"https://a.ex/cb?a=%2F&b=c%20d", "https://a.ex/cb?a=%2F&b=c%20d&loginToken=NEW"},
    {"https://app.ex/#/user/@bob:ex.org", "https://app.ex/?loginToken=NEW#/user/@bob:ex.org"},
    {"https://app.ex?x=1#/login", "https://app.ex?x=1&loginToken=NEW#/login"},
    # D20 corner cases
    {"https://a.ex/cb?loginToken=old#f", "https://a.ex/cb?loginToken=NEW#f"},
    {"https://a.ex/cb?loginToken&x=1", "https://a.ex/cb?x=1&loginToken=NEW"},
    {"https://a.ex/cb?loginToken=&x=1", "https://a.ex/cb?x=1&loginToken=NEW"},
    {"https://a.ex/cb?login%54oken=old&x=1", "https://a.ex/cb?x=1&loginToken=NEW"},
    {"https://a.ex/cb?a=%2F&loginToken=old&b=c%20d", "https://a.ex/cb?a=%2F&b=c%20d&loginToken=NEW"},
    {"https://a.ex/#/login?x=1&loginToken=old", "https://a.ex/?loginToken=NEW#/login?x=1"},
    {"https://a.ex/cb?loginToken=q#/login?loginToken=f", "https://a.ex/cb?loginToken=NEW#/login"},
    {"https://a.ex/cb?x=1&loginToken=q#/login?y=2&loginToken=f", "https://a.ex/cb?x=1&loginToken=NEW#/login?y=2"},
    # a fragment WITHOUT its own `?` query is not a query: nothing to remove
    {"https://a.ex/#loginToken=old", "https://a.ex/?loginToken=NEW#loginToken=old"},
    {"https://a.ex/cb?x=1&loginToken=old&loginToken=older&y=2&loginToken=oldest", "https://a.ex/cb?x=1&y=2&loginToken=NEW"}
  ]

  describe "D20 — append_login_token/2" do
    for {input, expected} <- @rows do
      test "#{inspect(input, limit: 80, printable_limit: 80)}" do
        assert SsoLogin.append_login_token(unquote(input), @new) == unquote(expected)
      end
    end

    test "exactly one loginToken parameter is in the result, whatever the input" do
      for {input, _} <- @rows do
        out = SsoLogin.append_login_token(input, @new)
        uri = URI.parse(out)
        frag_q = (uri.fragment || "") |> String.split("?", parts: 2) |> Enum.at(1) || ""

        names =
          [uri.query || "", frag_q]
          |> Enum.flat_map(&String.split(&1, "&", trim: true))
          |> Enum.map(fn kv -> kv |> String.split("=", parts: 2) |> hd() |> URI.decode() end)

        assert Enum.count(names, &(&1 == "loginToken")) == 1, "#{input} -> #{out}"
        assert out =~ "loginToken=NEW"
      end
    end

    test "the new token is the LAST query parameter of the base and the fragment is untouched otherwise" do
      out = SsoLogin.append_login_token("https://a.ex/cb?x=1&loginToken=old&y=2#/room/#a:ex.org", @new)
      assert out == "https://a.ex/cb?x=1&y=2&loginToken=NEW#/room/#a:ex.org"
    end

    test "a token value is appended verbatim (the 32-byte hex shape)" do
      token = String.duplicate("ab", 32)
      assert SsoLogin.append_login_token("https://a.ex/cb", token) == "https://a.ex/cb?loginToken=" <> token
    end
  end
end
