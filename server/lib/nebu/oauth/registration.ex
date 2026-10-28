defmodule Nebu.OAuth.Registration do
  @moduledoc """
  Validation + normalization of an RFC 7591 Dynamic Client Registration request (epic oauth-broker,
  story oauth-metadata-dcr-admin-approval, AC2/AC3). Pure functions — no I/O, no DB.

  `validate/1` turns the decoded JSON request body into the REGISTERED metadata (only supported
  fields and values, defaults applied) plus its `metadata_hash`, or into an RFC 7591 3.2.2 error
  `{:error, error_code, description}` with `error_code` one of `"invalid_redirect_uri"`,
  `"invalid_client_metadata"`, `"invalid_request"`.

  ## Registered metadata (everything else is dropped, never echoed, never stored)

  `client_name`, `client_uri` (required), `logo_uri`, `tos_uri`, `policy_uri`, `redirect_uris`
  (required, non-empty), `application_type` (`web`|`native`, default `web`),
  `token_endpoint_auth_method` (only `none`, default `none`), `response_types` (supported:
  `code`, default `["code"]`), `grant_types` (supported: `authorization_code`, `refresh_token`,
  default both). Unknown `response_types`/`grant_types` VALUES are ignored; a request whose
  (explicit) list does not contain `code` / `authorization_code` is rejected
  (`invalid_client_metadata`). Localized keys with a `#lang` suffix (`client_name#de`) are dropped.
  `client_secret` and every other unknown field is dropped (public clients have no secret).

  ## Hostile text (admins read these values in the approval UI)

    * `client_name` is rejected (`invalid_client_metadata`) when it contains a control character
      (incl. NUL — Postgres jsonb cannot store U+0000), a Unicode format character (bidi
      overrides/isolates, zero-width space/joiners, BOM, soft hyphen), a line/paragraph separator,
      a private-use or surrogate code point, or invalid UTF-8. It could otherwise reorder or hide
      text in the admin page.
    * every URI (`client_uri`, `logo_uri`, `tos_uri`, `policy_uri`, `redirect_uris`) is rejected
      when it contains whitespace, control/format/separator characters or backslashes.
    * every https URI host must be an ASCII LDH DNS name (letters, digits, hyphens; labels of at
      most 63, host of at most 253 characters). Non-ASCII hosts and punycode (`xn--`) labels are
      rejected: Unicode look-alikes of `/`, `.` or `@` (e.g. `https://evil.com／.example.com`)
      must never pass the host-suffix comparison, and an IDN could not be told apart from a
      look-alike of a trusted brand by the approving admin. The host must have at least TWO labels
      (`https://com` would otherwise "own" every `*.com` redirect) and its last label must not be
      all digits (an IPv4 literal such as `https://10.0.0.5`, or the host-suffix trick
      `https://0.1` for `127.0.0.1`; security review F-4). `valid_host?/1` is this predicate.
    * the `client_uri` host must NOT itself be a public suffix (`github.io`, `co.uk`, see
      `Nebu.OAuth.PublicSuffix`; story oauth-dcr-abuse-hardening, AH5): every redirect / logo / tos /
      policy host and every private-use scheme derives from the client host, so accepting
      `https://github.io` would make every `*.github.io` site "host-bound". `https://name.github.io`
      is accepted (the approval page warns about shared hosting). The registrable domain of the
      host is returned as `client_domain` (key of the per-source pending caps).

  ## Redirect URIs (Matrix spec v1.18 / oracle-context.md)

    * all: no fragment, no userinfo, no whitespace/control characters/backslashes
    * `web` — `https`, host equals the `client_uri` host or is a subdomain of it (any port, path,
      query)
    * `native`, claimed https — the same rules as `web`
    * `native`, loopback — `http://localhost`, `http://127.0.0.1` or `http://[::1]` WITHOUT a port
      at registration (any port is accepted at authorize time, story 2)
    * `native`, private-use scheme — the scheme is the reverse-DNS of the `client_uri` host (or
      extends it with further labels, e.g. host `example.com` => `com.example` / `com.example.app`)
      and the URI has NO authority component (`scheme:/path` or `scheme:path`, never `scheme://`)

  ## Metadata hash (dedup, AC3)

  SHA-256 (lowercase hex) of the canonical JSON — keys sorted, no whitespace — of the registered
  metadata with set-like lists (`redirect_uris`, `response_types`, `grant_types`) sorted. Defaults
  are applied BEFORE hashing, so an omitted field and its explicit default hash identically; key
  order, unknown fields, system/audit fields and `#lang` keys never influence the hash.
  """

  alias Nebu.OAuth.PublicSuffix

  @max_string 2048
  @max_name 255
  @max_redirect_uris 20

  @supported_response_types ["code"]
  @supported_grant_types ["authorization_code", "refresh_token"]

  # Control, format (bidi, zero-width, BOM, soft hyphen), private-use, surrogate, line/paragraph
  # separator code points: never legitimate in a client name or in a URI.
  @hostile_text_re ~r/[\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{Zl}\p{Zp}]/u
  # ... plus, for URIs, any whitespace/separator and backslashes.
  @unclean_uri_re ~r/[\s\\\p{Z}\p{Cc}\p{Cf}\p{Co}\p{Cs}]/u
  @dns_label_re ~r/\A(?!xn--)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/i

  @loopback_re ~r{\Ahttp://(localhost|127\.0\.0\.1|\[::1\])([/?]|\z)}i
  @scheme_re ~r/\A[a-z][a-z0-9+.\-]*\z/

  @type metadata :: %{optional(String.t()) => term()}
  @type result ::
          {:ok,
             %{
               metadata: metadata(),
               hash: String.t(),
               application_type: String.t(),
               token_endpoint_auth_method: String.t(),
               client_host: String.t(),
               client_domain: String.t() | nil
             }}
          | {:error, String.t(), String.t()}

  @doc "Validates and normalizes a decoded request body."
  @spec validate(term()) :: result()
  def validate(body) when is_map(body) and map_size(body) > 0 do
    body = drop_lang_keys(body)

    with {:ok, client_uri, client_host} <- client_uri(body),
         {:ok, client_domain} <- not_public_suffix(client_host),
         {:ok, application_type} <- application_type(body),
         {:ok, auth_method} <- auth_method(body),
         {:ok, client_name} <- optional_string(body, "client_name", @max_name),
         {:ok, aux} <- aux_uris(body, client_host),
         {:ok, response_types} <- types(body, "response_types", "code", @supported_response_types),
         {:ok, grant_types} <- types(body, "grant_types", "authorization_code", @supported_grant_types),
         {:ok, redirect_uris} <- redirect_uris(body, application_type, client_host) do
      metadata =
        %{
          "client_uri" => client_uri,
          "redirect_uris" => redirect_uris,
          "application_type" => application_type,
          "token_endpoint_auth_method" => auth_method,
          "response_types" => response_types,
          "grant_types" => grant_types
        }
        |> put_unless_nil("client_name", client_name)
        |> Map.merge(aux)

      {:ok,
       %{
         metadata: metadata,
         hash: hash(metadata),
         application_type: application_type,
         token_endpoint_auth_method: auth_method,
         # lower-cased client_uri host: the key of the per-host pending cap (not part of the hash)
         client_host: client_host,
         # registrable domain of the host (AH6): key of the per-(domain, source) pending cap
         client_domain: client_domain
       }}
    end
  end

  def validate(_other),
    do: {:error, "invalid_request", "The request body must be a non-empty JSON object."}

  @doc "SHA-256 (lowercase hex) over the canonical JSON of `metadata` (set-like lists sorted)."
  @spec hash(metadata()) :: String.t()
  def hash(metadata) do
    metadata
    |> Map.update("redirect_uris", [], &Enum.sort/1)
    |> Map.update("response_types", [], &Enum.sort/1)
    |> Map.update("grant_types", [], &Enum.sort/1)
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Canonical JSON: object keys sorted bytewise, no whitespace. Exposed for tests/documentation."
  @spec canonical_json(term()) :: binary()
  def canonical_json(term), do: term |> canonical_iodata() |> IO.iodata_to_binary()

  defp canonical_iodata(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> [Jason.encode!(to_string(k)), ":", canonical_iodata(v)] end)
      |> Enum.intersperse(",")

    ["{", members, "}"]
  end

  defp canonical_iodata(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical_iodata/1) |> Enum.intersperse(","), "]"]

  defp canonical_iodata(other), do: Jason.encode!(other)

  # ── field validators ────────────────────────────────────────────────────────

  defp drop_lang_keys(map),
    do: map |> Enum.reject(fn {k, _} -> is_binary(k) and String.contains?(k, "#") end) |> Map.new()

  defp client_uri(body) do
    case Map.get(body, "client_uri") do
      nil ->
        meta_error("client_uri is required.")

      uri when is_binary(uri) ->
        case parse_https(uri) do
          {:ok, parsed} -> {:ok, uri, String.downcase(parsed.host)}
          :error -> meta_error("client_uri must be an https URL without userinfo.")
        end

      _ ->
        meta_error("client_uri must be a string.")
    end
  end

  # AH5: a client_uri host that IS a public suffix is refused; otherwise its registrable domain.
  defp not_public_suffix(client_host) do
    case PublicSuffix.classify(client_host) do
      {:ok, %{public_suffix?: true}} ->
        meta_error(
          "client_uri must not be a public suffix such as github.io; use your own site, e.g. name.github.io."
        )

      {:ok, %{domain: domain}} ->
        {:ok, domain}

      {:error, _} ->
        # unreachable for a host that passed valid_host?/1 (>= 2 labels); never a crash
        {:ok, nil}
    end
  end

  defp application_type(body) do
    case Map.get(body, "application_type", "web") do
      type when type in ["web", "native"] -> {:ok, type}
      _ -> meta_error("application_type must be \"web\" or \"native\".")
    end
  end

  defp auth_method(body) do
    case Map.get(body, "token_endpoint_auth_method", "none") do
      "none" -> {:ok, "none"}
      _ -> meta_error("Only token_endpoint_auth_method \"none\" is supported.")
    end
  end

  defp optional_string(body, key, max) do
    case Map.get(body, key) do
      nil -> {:ok, nil}
      v when is_binary(v) and byte_size(v) <= max -> text_without_hostile_chars(key, v)
      _ -> meta_error("#{key} must be a string of at most #{max} bytes.")
    end
  end

  defp text_without_hostile_chars(key, value) do
    if String.valid?(value) and not Regex.match?(@hostile_text_re, value),
      do: {:ok, value},
      else: meta_error("#{key} must not contain control, bidirectional-override or zero-width characters.")
  end

  # logo_uri / tos_uri / policy_uri: https, no userinfo, on the client_uri host or a subdomain.
  defp aux_uris(body, client_host) do
    Enum.reduce_while(~w(logo_uri tos_uri policy_uri), {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.get(body, key) do
        nil ->
          {:cont, {:ok, acc}}

        uri when is_binary(uri) and byte_size(uri) <= @max_string ->
          case parse_https(uri) do
            {:ok, parsed} ->
              if host_under?(String.downcase(parsed.host), client_host) and clean?(uri) do
                {:cont, {:ok, Map.put(acc, key, uri)}}
              else
                {:halt, meta_error("#{key} must be on the client_uri host.")}
              end

            :error ->
              {:halt, meta_error("#{key} must be an https URL without userinfo.")}
          end

        _ ->
          {:halt, meta_error("#{key} must be an https URL string.")}
      end
    end)
  end

  # Present list: keep supported values (deduplicated, sorted); it MUST contain `required`.
  # Absent: the server default (all supported values). Non-list: invalid.
  defp types(body, key, required, supported) do
    case Map.fetch(body, key) do
      :error ->
        {:ok, supported}

      {:ok, list} when is_list(list) ->
        kept = list |> Enum.filter(&(&1 in supported)) |> Enum.uniq() |> Enum.sort()

        if required in kept,
          do: {:ok, kept},
          else: meta_error("#{key} must include \"#{required}\".")

      {:ok, _} ->
        meta_error("#{key} must be an array of strings.")
    end
  end

  # ── redirect URIs ───────────────────────────────────────────────────────────

  defp redirect_uris(body, application_type, client_host) do
    case Map.get(body, "redirect_uris") do
      [_ | _] = uris when length(uris) <= @max_redirect_uris ->
        uris
        |> Enum.reduce_while({:ok, []}, fn uri, {:ok, acc} ->
          if valid_redirect_uri?(uri, application_type, client_host),
            do: {:cont, {:ok, [uri | acc]}},
            else: {:halt, {:error, "invalid_redirect_uri", "redirect_uris contains an invalid redirect URI."}}
        end)
        |> case do
          {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
          error -> error
        end

      _ ->
        {:error, "invalid_redirect_uri",
         "redirect_uris must be a non-empty array of at most #{@max_redirect_uris} URIs."}
    end
  end

  defp valid_redirect_uri?(uri, application_type, client_host) when is_binary(uri) do
    byte_size(uri) <= @max_string and clean?(uri) and not String.contains?(uri, "#") and
      do_valid_redirect_uri?(uri, application_type, client_host)
  end

  defp valid_redirect_uri?(_uri, _type, _host), do: false

  defp do_valid_redirect_uri?(uri, "web", client_host), do: claimed_https?(uri, client_host)

  defp do_valid_redirect_uri?(uri, "native", client_host) do
    cond do
      String.match?(uri, ~r/\Ahttps:/i) -> claimed_https?(uri, client_host)
      String.match?(uri, ~r/\Ahttp:/i) -> loopback?(uri)
      true -> private_use_scheme?(uri, client_host)
    end
  end

  defp claimed_https?(uri, client_host) do
    case parse_https(uri) do
      {:ok, parsed} -> host_under?(String.downcase(parsed.host), client_host)
      :error -> false
    end
  end

  # http://localhost | http://127.0.0.1 | http://[::1], followed directly by `/`, `?` or the end:
  # that rules out a port (`:1234`), userinfo (`user:pass@`) and look-alike hosts
  # (`localhost.example.com`) in one anchored match.
  defp loopback?(uri), do: Regex.match?(@loopback_re, uri)

  # scheme:/path or scheme:path — NO authority (`scheme://...`), scheme = reverse-DNS of client host.
  defp private_use_scheme?(uri, client_host) do
    case String.split(uri, ":", parts: 2) do
      [scheme, rest] when rest != "" ->
        scheme = String.downcase(scheme)
        reverse = reverse_dns(client_host)

        String.match?(scheme, @scheme_re) and not String.starts_with?(rest, "//") and
          String.contains?(reverse, ".") and
          (scheme == reverse or String.starts_with?(scheme, reverse <> "."))

      _ ->
        false
    end
  end

  defp reverse_dns(host), do: host |> String.split(".") |> Enum.reverse() |> Enum.join(".")

  # ── helpers ─────────────────────────────────────────────────────────────────

  # https URL with an ASCII LDH DNS host and no userinfo (and no whitespace/control/format chars
  # or backslashes anywhere in the URI).
  defp parse_https(uri) when byte_size(uri) <= @max_string do
    if clean?(uri) do
      parsed = URI.parse(uri)

      if parsed.scheme == "https" and is_binary(parsed.host) and parsed.userinfo == nil and
           valid_host?(parsed.host),
         do: {:ok, parsed},
         else: :error
    else
      :error
    end
  end

  defp parse_https(_), do: :error

  defp clean?(uri), do: String.valid?(uri) and not Regex.match?(@unclean_uri_re, uri)

  # ASCII letters/digits/hyphens only, dot separated, no empty label, no `xn--` (punycode) label.
  # Checked on the RAW host (before downcasing), so e.g. U+212A KELVIN SIGN never folds into `k`.
  # F-4 / N-2: at least TWO labels and a last label that is not a NUMBER in the WHATWG URL sense
  # ("ends in a number"): all digits (`10.0.0.5`, the short form `0.1`) or `0x` + hex digits
  # (`127.0.0.0x1`, `0x7f.0x1`, both parsed as IPv4 literals). A real TLD is never numeric.
  @doc """
  The registration's host rule as a predicate: an ASCII LDH DNS name of at least two labels, labels
  of at most 63 and the host of at most 253 characters, no `xn--` label, and a last label that is
  not a number. Case-insensitive, no trimming. Also used for the host input of the admin bulk
  removal (`Nebu.OAuth.ClientStore.bulk_delete_pending/3`).
  """
  @spec valid_host?(term()) :: boolean()
  def valid_host?(host) when is_binary(host) and byte_size(host) <= 253 do
    labels = String.split(host, ".")

    length(labels) >= 2 and Enum.all?(labels, &Regex.match?(@dns_label_re, &1)) and
      not Regex.match?(~r/\A(0x[0-9a-f]*|[0-9]+)\z/i, List.last(labels))
  end

  def valid_host?(_host), do: false

  defp host_under?(host, base), do: host == base or String.ends_with?(host, "." <> base)

  defp meta_error(description), do: {:error, "invalid_client_metadata", description}

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
