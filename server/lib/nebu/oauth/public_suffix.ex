defmodule Nebu.OAuth.PublicSuffix do
  @moduledoc """
  Built-in public-suffix classification (epic oauth-broker, story oauth-dcr-abuse-hardening, AH4,
  gate item 3). Pure functions over compile-time data: no network, no database, no process state.

  It answers three questions about a DNS host: what is its REGISTRABLE domain (public suffix plus
  one label), is the host itself a public suffix (`github.io`, `co.uk`), and does it live below a
  multi-tenant hosting suffix (`name.github.io`: anyone can create sites there).

  ## The list

  Two hand-picked sets of lowercase names (NOT a copy of the Mozilla list): `:icann` (country-code
  second-level registries such as `co.uk`) and `:private` (multi-tenant hosting platforms such as
  `github.io`). There are no wildcard or exception rules. The LONGEST listed suffix that equals the
  host or is a dot-suffix of it wins (`bucket.s3.amazonaws.com` is its own registrable domain
  because `s3.amazonaws.com` is listed); a host matching nothing uses the default rule: the last
  label is the suffix. A suffix missing from the list only means coarser grouping and no warning
  badge, never a weaker check elsewhere (the pending caps are keyed on the client source as well).

  ## Extending the list

  Add the lowercase suffix to the right set below, add a test row in `public_suffix_test.exs`, and
  add the name to the list in ADR-033 (section "DCR and flow-state abuse hardening").
  """

  @icann ~w(co.uk org.uk ac.uk gov.uk me.uk ltd.uk plc.uk net.uk
            com.au net.au org.au edu.au gov.au co.nz org.nz co.jp ne.jp or.jp
            com.br net.br org.br gov.br edu.br com.cn com.mx co.za co.in com.tr com.sg co.kr com.tw
            com.hk com.ar co.il org.il ac.il gov.il net.il muni.il com.pl net.pl org.pl co.th ac.th
            or.th go.th in.th net.th co.id ac.id or.id go.id web.id com.ua net.ua org.ua gov.ua
            com.ph com.pk com.eg com.sa com.my com.vn com.ng co.ke com.co com.pe co.at or.at)

  @private ~w(github.io githubusercontent.com gitlab.io bitbucket.io vercel.app now.sh netlify.app
              herokuapp.com pages.dev workers.dev trycloudflare.com azurewebsites.net
              azurestaticapps.net cloudapp.net blogspot.com appspot.com web.app firebaseapp.com
              fly.dev onrender.com glitch.me surge.sh readthedocs.io ngrok.io ngrok-free.app
              ngrok.app s3.amazonaws.com cloudfront.net amplifyapp.com duckdns.org wordpress.com
              wixsite.com myshopify.com r2.dev deno.dev up.railway.app loca.lt elasticbeanstalk.com
              cloudapp.azure.com github.dev)

  @icann_set MapSet.new(@icann)
  @private_set MapSet.new(@private)

  @max_host_bytes 253

  @type kind :: :icann | :private | :default
  @type info :: %{domain: String.t(), suffix: String.t(), kind: kind(), public_suffix?: boolean()}

  @doc """
  Classifies `host` (case-insensitive): `{:ok, %{domain:, suffix:, kind:, public_suffix?:}}`, or
  `{:error, :invalid_host}` for anything that is not a DNS name with at least two labels (empty
  label, trailing dot, a single label, more than 253 bytes, not a string).

  For a host that IS a listed suffix, `domain` and `suffix` are the host itself and
  `public_suffix?` is `true`. For an ordinary host, `domain` is the matched suffix plus one label.
  """
  @spec classify(term()) :: {:ok, info()} | {:error, :invalid_host}
  def classify(host) when is_binary(host) and byte_size(host) <= @max_host_bytes do
    host = String.downcase(host)
    labels = String.split(host, ".")

    if length(labels) >= 2 and Enum.all?(labels, &(&1 != "")) do
      {:ok, do_classify(host, labels)}
    else
      {:error, :invalid_host}
    end
  end

  def classify(_host), do: {:error, :invalid_host}

  @doc "The registrable domain of `host`, or `{:error, :invalid_host}`."
  @spec registrable_domain(term()) :: {:ok, String.t()} | {:error, :invalid_host}
  def registrable_domain(host) do
    case classify(host) do
      {:ok, %{domain: domain}} -> {:ok, domain}
      {:error, _} = error -> error
    end
  end

  @doc "`true` when `host` itself is a listed public suffix (`github.io`, `co.uk`); `false` otherwise."
  @spec public_suffix?(term()) :: boolean()
  def public_suffix?(host) do
    match?({:ok, %{public_suffix?: true}}, classify(host))
  end

  @doc """
  `true` when the matched suffix is `:private` (multi-tenant hosting) and `host` is BELOW it
  (`name.github.io`, not `github.io` itself).
  """
  @spec shared_hosting?(term()) :: boolean()
  def shared_hosting?(host) do
    match?({:ok, %{kind: :private, public_suffix?: false}}, classify(host))
  end

  @doc "The built-in lists (`%{icann: [..], private: [..]}`), for documentation and tests."
  @spec suffixes() :: %{icann: [String.t()], private: [String.t()]}
  def suffixes, do: %{icann: @icann, private: @private}

  # ── internals ───────────────────────────────────────────────────────────────

  # Longest listed suffix first: try every dot-suffix of the host, longest to shortest.
  defp do_classify(host, labels) do
    case longest_listed(labels) do
      {suffix, kind} ->
        suffix_labels = length(String.split(suffix, "."))

        if suffix_labels == length(labels) do
          %{domain: host, suffix: suffix, kind: kind, public_suffix?: true}
        else
          domain = labels |> Enum.take(-(suffix_labels + 1)) |> Enum.join(".")
          %{domain: domain, suffix: suffix, kind: kind, public_suffix?: false}
        end

      nil ->
        # default rule: the last label is the suffix
        %{
          domain: labels |> Enum.take(-2) |> Enum.join("."),
          suffix: List.last(labels),
          kind: :default,
          public_suffix?: false
        }
    end
  end

  defp longest_listed(labels) do
    0..(length(labels) - 1)//1
    |> Enum.find_value(fn drop ->
      candidate = labels |> Enum.drop(drop) |> Enum.join(".")

      cond do
        MapSet.member?(@private_set, candidate) -> {candidate, :private}
        MapSet.member?(@icann_set, candidate) -> {candidate, :icann}
        true -> nil
      end
    end)
  end
end
