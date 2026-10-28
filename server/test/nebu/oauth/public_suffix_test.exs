defmodule Nebu.OAuth.PublicSuffixTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-dcr-abuse-hardening`, AC1 (AH4): the pure module
  `Nebu.OAuth.PublicSuffix` (built-in list, no network, no DB).

  ATDD decisions pinned here (the story leaves the exact return shapes of the wrappers open):

    * `classify/1` is exactly as AC1.1: `{:ok, %{domain:, suffix:, kind:, public_suffix?:}}` or
      `{:error, :invalid_host}`; `kind` is `:icann | :private | :default`.
    * `registrable_domain/1` returns the domain string, optionally wrapped as `{:ok, domain}`
      (both accepted); `{:error, :invalid_host}` / `nil` for an invalid host.
    * `public_suffix?/1` and `shared_hosting?/1` are plain booleans (`false` for an invalid host).
    * `suffixes/0` returns `%{icann: [..], private: [..]}` (lists or MapSets).

  All calls go through `apply/3`, so this file compiles before the module exists and the rest of
  the suite keeps running; the tests fail with `UndefinedFunctionError` until the implementation
  lands.
  """
  use ExUnit.Case, async: true

  @ps Nebu.OAuth.PublicSuffix

  @icann ~w(co.uk org.uk ac.uk gov.uk me.uk ltd.uk plc.uk net.uk co.nz org.nz co.jp ne.jp or.jp com.br
            com.cn com.mx co.za co.in com.tr com.sg co.kr com.tw com.hk com.ar com.au net.au org.au
            edu.au gov.au net.br org.br gov.br edu.br co.il org.il ac.il gov.il net.il muni.il com.pl
            net.pl org.pl co.th ac.th or.th go.th in.th net.th co.id ac.id or.id go.id web.id com.ua
            net.ua org.ua gov.ua com.ph com.pk com.eg com.sa com.my com.vn com.ng co.ke com.co com.pe
            co.at or.at)
  @private ~w(github.io githubusercontent.com gitlab.io bitbucket.io vercel.app now.sh netlify.app
              herokuapp.com pages.dev workers.dev trycloudflare.com azurewebsites.net azurestaticapps.net
              cloudapp.net blogspot.com appspot.com web.app firebaseapp.com fly.dev onrender.com glitch.me
              surge.sh readthedocs.io ngrok.io ngrok-free.app ngrok.app s3.amazonaws.com cloudfront.net
              amplifyapp.com duckdns.org wordpress.com wixsite.com myshopify.com r2.dev deno.dev
              up.railway.app loca.lt elasticbeanstalk.com cloudapp.azure.com github.dev)

  defp classify(host), do: apply(@ps, :classify, [host])

  defp unwrap({:ok, v}), do: v
  defp unwrap(v), do: v

  describe "AC1.1 — classify/1 shape" do
    test "returns the documented map for an ordinary domain" do
      assert {:ok, %{domain: "example.com", suffix: "com", kind: :default, public_suffix?: false}} = classify("example.com")
    end

    test "lowercases the input" do
      assert {:ok, %{domain: "example.com"}} = classify("WWW.Example.COM")
    end

    for {label, host} <- [
          {"empty string", ""},
          {"empty label", "a..example.com"},
          {"leading dot", ".example.com"},
          {"trailing dot", "example.com."},
          {"single label", "localhost"},
          {"single label that is a TLD", "com"},
          {"more than 253 bytes", String.duplicate("a", 63) <> "." <> String.duplicate("b", 63) <> "." <> String.duplicate("c", 63) <> "." <> String.duplicate("d", 63) <> ".com"}
        ] do
      test "#{label} => {:error, :invalid_host}" do
        assert classify(unquote(host)) == {:error, :invalid_host}
      end
    end

    test "the wrappers never raise on an invalid host" do
      for host <- ["", "a..b", "localhost", "example.com."] do
        refute apply(@ps, :public_suffix?, [host])
        refute apply(@ps, :shared_hosting?, [host])
      end
    end
  end

  describe "AC1.2 — table" do
    test "example.com => example.com (:default)" do
      assert {:ok, %{domain: "example.com", kind: :default, public_suffix?: false}} = classify("example.com")
      assert unwrap(apply(@ps, :registrable_domain, ["example.com"])) == "example.com"
    end

    test "a.b.example.com => example.com" do
      assert {:ok, %{domain: "example.com"}} = classify("a.b.example.com")
      assert unwrap(apply(@ps, :registrable_domain, ["a.b.example.com"])) == "example.com"
    end

    test "foo.co.uk and x.foo.co.uk => foo.co.uk (:icann suffix co.uk)" do
      assert {:ok, %{domain: "foo.co.uk", suffix: "co.uk", kind: :icann, public_suffix?: false}} = classify("foo.co.uk")
      assert {:ok, %{domain: "foo.co.uk", suffix: "co.uk", kind: :icann}} = classify("x.foo.co.uk")
    end

    test "co.uk, github.io and GitHub.IO are public suffixes themselves" do
      for host <- ["co.uk", "github.io", "GitHub.IO"] do
        assert {:ok, %{public_suffix?: true}} = classify(host)
        assert apply(@ps, :public_suffix?, [host]) == true
      end
    end

    test "name.github.io and a.name.github.io => name.github.io (shared hosting, :private)" do
      for host <- ["name.github.io", "a.name.github.io"] do
        assert {:ok, %{domain: "name.github.io", suffix: "github.io", kind: :private, public_suffix?: false}} = classify(host)
        assert apply(@ps, :shared_hosting?, [host]) == true
        assert apply(@ps, :public_suffix?, [host]) == false
      end
    end

    test "shared_hosting? is false for the suffix itself, for ICANN suffixes and for ordinary domains" do
      refute apply(@ps, :shared_hosting?, ["github.io"]), "the host must be BELOW the private suffix"
      refute apply(@ps, :shared_hosting?, ["foo.co.uk"])
      refute apply(@ps, :shared_hosting?, ["app.example.com"])
    end

    test "longest listed suffix wins: bucket.s3.amazonaws.com is its own registrable domain" do
      assert {:ok, %{domain: "bucket.s3.amazonaws.com", suffix: "s3.amazonaws.com", kind: :private}} = classify("bucket.s3.amazonaws.com")
      assert {:ok, %{domain: "bucket.s3.amazonaws.com"}} = classify("a.bucket.s3.amazonaws.com")
      assert {:ok, %{public_suffix?: true}} = classify("s3.amazonaws.com")
      # amazonaws.com itself is NOT listed: default rule
      assert {:ok, %{domain: "amazonaws.com", kind: :default}} = classify("amazonaws.com")
    end

    test "notgithub.io is NOT below github.io (label boundary): default rule" do
      assert {:ok, %{domain: "notgithub.io", kind: :default, public_suffix?: false}} = classify("notgithub.io")
      assert {:ok, %{domain: "notgithub.io"}} = classify("www.notgithub.io")
    end

    test "every suffix of the story list is recognised with the right kind" do
      for s <- @icann do
        assert {:ok, %{public_suffix?: true, kind: :icann}} = classify(s), "#{s} must be an :icann public suffix"
        assert {:ok, %{domain: d, kind: :icann}} = classify("tenant." <> s)
        assert d == "tenant." <> s
      end

      for s <- @private do
        assert {:ok, %{public_suffix?: true, kind: :private}} = classify(s), "#{s} must be a :private public suffix"
        assert {:ok, %{domain: d, kind: :private}} = classify("tenant." <> s)
        assert d == "tenant." <> s
        assert apply(@ps, :shared_hosting?, ["tenant." <> s])
      end
    end
  end

  describe "AC1.3 — static list invariants (suffixes/0)" do
    defp sets do
      case apply(@ps, :suffixes, []) do
        %{icann: i, private: p} -> {Enum.to_list(i), Enum.to_list(p)}
        kw when is_list(kw) -> {Enum.to_list(Keyword.fetch!(kw, :icann)), Enum.to_list(Keyword.fetch!(kw, :private))}
      end
    end

    test "every entry is a lowercase LDH name with at least two labels" do
      {icann, private} = sets()
      assert icann != [] and private != []

      for s <- icann ++ private do
        assert s == String.downcase(s), "#{s} must be lowercase"
        assert s =~ ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/, "#{s} must be LDH with >= 2 labels"
      end
    end

    test "no duplicates within or across the two sets" do
      {icann, private} = sets()
      all = icann ++ private
      assert length(all) == length(Enum.uniq(all)), "duplicates: #{inspect(all -- Enum.uniq(all))}"
    end

    test "the lists contain (at least) every name the story pins" do
      {icann, private} = sets()
      assert @icann -- icann == [], "missing :icann entries: #{inspect(@icann -- icann)}"
      assert @private -- private == [], "missing :private entries: #{inspect(@private -- private)}"
    end
  end

  describe "AC1 — purity" do
    test "the module source does no network or DB access" do
      path = Path.expand("../../../lib/nebu/oauth/public_suffix.ex", __DIR__)
      assert File.exists?(path), "server/lib/nebu/oauth/public_suffix.ex is missing"
      # strip the docs and comments: only executable code is checked, whole words only
      src =
        path
        |> File.read!()
        |> String.replace(~r/@(module)?doc \"\"\".*?\"\"\"/s, "")
        |> String.replace(~r/^\s*#.*$/m, "")

      refute src =~ ~r/\b(Repo|Ecto|HTTPoison|Req|Finch)\b|:httpc|:gen_tcp/, "the list is compile-time data (AH4, AH16)"
    end
  end
end
