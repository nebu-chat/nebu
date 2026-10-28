defmodule Nebu.Admin.OAuthRegistrationsHTML do
  @moduledoc "Template module for OAuthRegistrationsController."
  use Phoenix.Component

  embed_templates "templates/oauth_registrations/*"

  @doc false
  # Registration time as `YYYY-MM-DD HH:MM:SS UTC` (an em-dash when absent).
  def format_created(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  def format_created(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  def format_created(_), do: "—"

  @doc false
  # The <img src> of a logo, ONLY when logos were requested (`?logos=1`) AND the logo has a safe
  # origin (see logo_origin/1: https, plain ASCII host, no userinfo) — so the CSP origins the
  # controller allows and the images the template renders are exactly the same set. Anything else
  # renders no image (the URL stays visible as text).
  def safe_logo(%{logo_uri: uri} = client, show_logos?) do
    if show_logos? and logo_origin(uri) != nil, do: client.logo_uri, else: nil
  end

  def safe_logo(_client, _show_logos?), do: nil

  @doc false
  # True when the row has a logo that COULD be loaded on request (drives the "Load logos" control).
  def loadable_logo?(%{logo_uri: uri}), do: logo_origin(uri) != nil
  def loadable_logo?(_), do: false

  @doc false
  # The CSP source (`https://host[:port]`) of a logo URL, or nil. Deliberately strict because the
  # value is put verbatim into the Content-Security-Policy header: https only, no userinfo, host =
  # ASCII letters/digits/dots/hyphens (registration enforces ASCII LDH; rows inserted by other
  # means are re-checked here), explicit port only when it is not 443. Security review F-4: a DNS
  # name only — at least two labels and a last label that is not all digits, so an IPv4 literal
  # (`https://10.0.0.5/logo.png`) can neither widen the CSP to an intranet origin nor make the
  # admin's browser request it.
  def logo_origin("https://" <> _ = uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, userinfo: nil, port: port} when is_binary(host) ->
        if Regex.match?(~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/, host) and dns_name?(host) and
             is_integer(port) and port in 1..65_535 do
          "https://" <> String.downcase(host) <> if(port == 443, do: "", else: ":#{port}")
        end

      _ ->
        nil
    end
  end

  def logo_origin(_), do: nil

  # >= 2 labels, no empty label, last label not a number (all digits, or `0x` + hex digits: IPv4
  # literal / short form / hex notation, security review F-4 + N-2).
  defp dns_name?(host) do
    labels = String.split(host, ".")

    length(labels) >= 2 and Enum.all?(labels, &(&1 != "")) and
      not Regex.match?(~r/\A(0x[0-9a-f]*|[0-9]+)\z/i, List.last(labels))
  end

  @doc false
  # Host of a URI as text (what the admin must recognise), or nil.
  def uri_host(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  def uri_host(_), do: nil

  @doc false
  # Link of a list page: `?page=N` (omitted for page 1) and `&logos=1` when logos are on.
  def list_href(page, show_logos?) do
    query = if(page > 1, do: ["page=#{page}"], else: []) ++ if(show_logos?, do: ["logos=1"], else: [])

    case query do
      [] -> "/admin/oauth/registrations"
      parts -> "/admin/oauth/registrations?" <> Enum.join(parts, "&")
    end
  end

  @doc false
  # Link of the approve confirm page; it carries `page` / `logos` so the redirect after the decision returns to where the
  # list was opened.
  def approve_href(client, page, show_logos?) do
    query = if(page > 1, do: ["page=#{page}"], else: []) ++ if(show_logos?, do: ["logos=1"], else: [])

    base = "/admin/oauth/registrations/" <> URI.encode(client.client_id, &URI.char_unreserved?(&1)) <> "/approve"
    if query == [], do: base, else: base <> "?" <> Enum.join(query, "&")
  end

  @doc false
  # Link target of the client URI: https only (same guard as safe_logo/1).
  def safe_link("https://" <> _ = uri), do: uri
  def safe_link(_), do: nil

  @doc false
  # The host of the client URI (what the admin must recognise: the full URI is attacker-chosen
  # text, userinfo/lookalike tricks live in the rest of it), or nil when there is none.
  def client_host(%{client_uri: uri}), do: uri_host(uri)
  def client_host(_), do: nil

  @doc false
  # Text of the native confirm() dialog. The VERIFIED part comes first: the client URI host (the
  # name is an unverified, attacker-chosen claim and could even contain a fake "(app.example.com)"),
  # then the name as a JSON string: `Approve client at <host> (name "<name>")? <consequence>`
  # (security review F-5). Story oauth-hardening-hygiene (HY6, I-10): the name is cut to 80 graphemes (`…`
  # appended) BEFORE it is JSON-encoded, so a quote / backslash / control character in the attacker-chosen name
  # is escaped (`\"`, `\\`, `\n`, `\u0001`) and can neither fake a second "at <host>" clause nor break the native
  # dialog. Never raises: invalid UTF-8 is replaced by U+FFFD first.
  def confirm_text(client, verb, consequence) do
    subject =
      case client_host(client) do
        nil -> "client " <> inspect_name(client)
        host -> "client at " <> host <> " (name " <> inspect_name(client) <> ")"
      end

    verb <> " " <> subject <> "? " <> consequence
  end

  @max_name_graphemes 80

  defp inspect_name(%{client_name: name}) when is_binary(name) and name != "", do: name |> clean_utf8() |> truncate_name() |> Jason.encode!()
  defp inspect_name(%{client_id: id}), do: Jason.encode!("(unnamed client " <> to_string(id) <> ")")

  # `Jason.encode!/1` raises on invalid UTF-8: a name read from the database is text, but this function must never
  # 500 the admin page.
  defp clean_utf8(text), do: if(String.valid?(text), do: text, else: String.replace_invalid(text, "\uFFFD"))

  defp truncate_name(text) do
    if String.length(text) > @max_name_graphemes, do: String.slice(text, 0, @max_name_graphemes) <> "…", else: text
  end

  @doc false
  # `:host_bound` when the redirect URI is an https URI (registration only admits https redirect
  # URIs on the client_uri host or a subdomain of it), `:not_host_bound` for loopback (http://localhost,
  # 127.0.0.1, [::1]) and private-use-scheme URIs: those are NOT tied to the client_uri host, so the
  # client's name, URI and logo are unverified claims (security review F-5).
  def redirect_binding("https://" <> _), do: :host_bound
  def redirect_binding(_), do: :not_host_bound

  @doc false
  # True when at least one redirect URI of the client is not host-bound.
  def any_unbound?(%{redirect_uris: uris}) when is_list(uris),
    do: Enum.any?(uris, &(redirect_binding(&1) == :not_host_bound))

  def any_unbound?(_), do: false

  @doc false
  # An https redirect URI whose host differs from the client_uri host (a subdomain): highlighted so
  # the admin sees where the authorization code would be delivered.
  def other_host?(client, uri) do
    redirect_binding(uri) == :host_bound and uri_host(uri) != nil and
      String.downcase(uri_host(uri)) != String.downcase(client_host(client) || "")
  end

  # ── host classification and bulk removal (story oauth-dcr-abuse-hardening, AC7, AC9) ────────────

  @bulk_path "/admin/oauth/registrations/bulk-remove"

  @doc false
  # `Nebu.OAuth.host_info/1` of the client URI host (ADR-020: the suffix logic stays in the OAuth
  # domain), or nil. Derived at render time, so rows without stored columns get the same badges.
  def host_info(client) do
    case client_host(client) do
      nil -> nil
      host -> Nebu.OAuth.host_info(host)
    end
  end

  @doc false
  # The registrable domain, only when it is something the admin does not already see in the host.
  def client_domain_note(client) do
    case {client_host(client), host_info(client)} do
      {host, %{domain: domain}} when is_binary(host) ->
        if domain != String.downcase(host), do: domain

      _ ->
        nil
    end
  end

  @doc false
  # `{href, label_domain}` of the row's "remove all pending registrations of ..." link, or nil when the
  # host is not a valid registration host. A host that IS a public suffix (legacy rows) can only be
  # removed by exact host: a `domain` match on a suffix is refused (AH9).
  def bulk_link(client) do
    case host_info(client) do
      %{valid?: true, public_suffix?: true} ->
        host = String.downcase(client_host(client))
        {@bulk_path <> "?" <> URI.encode_query([{"host", host}, {"match", "exact"}]), host}

      %{valid?: true, domain: domain} ->
        {@bulk_path <> "?" <> URI.encode_query([{"host", domain}, {"match", "domain"}]), domain}

      _ ->
        nil
    end
  end

  @doc false
  def bulk_path, do: @bulk_path

  @doc false
  def plural(1, one, _many), do: "1 " <> one
  def plural(n, _one, many), do: "#{n} " <> many

  @doc false
  # The criteria in words (host as typed, trimmed), e.g. `registrable domain t1.com and its
  # subdomains, older than 30 days`.
  def bulk_words(%{host: host, match: match, older_than_days: days}) do
    host_part =
      case String.trim(host) do
        "" ->
          nil

        trimmed ->
          lowered = String.downcase(trimmed)

          if match == "exact" do
            "host " <> lowered
          else
            "registrable domain " <> registrable_domain(lowered) <> " and its subdomains"
          end
      end

    age_part =
      case String.trim(days) do
        "" -> nil
        d -> "older than " <> d <> " days"
      end

    case Enum.reject([host_part, age_part], &is_nil/1) do
      [] -> "(none)"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp registrable_domain(host) do
    case Nebu.OAuth.host_info(host) do
      %{domain: domain} -> domain
      _ -> host
    end
  end

  @doc false
  def bulk_confirm_text(count, form),
    do: "Remove " <> plural(count, "pending registration", "pending registrations") <> " matching " <> bulk_words(form) <> "? This cannot be undone."

  @doc false
  def bulk_error_text({:invalid, :no_criteria}), do: "Enter a host or domain, an age in days, or both."
  def bulk_error_text({:invalid, :host}), do: "The host is not a valid DNS name: letters, digits, hyphens and dots, at least two labels."

  def bulk_error_text({:invalid, :older_than_days}), do: "Older than (days) must be a whole number between 1 and 3650."

  def bulk_error_text({:invalid, :public_suffix}),
    do: "A public suffix such as github.io cannot be removed as a domain. Choose \"Exact host\" or enter the full host."

  def bulk_error_text({:invalid, :match}), do: "Choose how the host is matched: registrable domain or exact host."
  def bulk_error_text(:storage), do: "The preview could not be loaded. Please try again."
  def bulk_error_text(_), do: "The removal criteria are invalid."

  @doc false
  # Which inputs an error marks `aria-invalid`.
  def bulk_invalid?({:invalid, reason}, :host), do: reason in [:no_criteria, :host, :public_suffix]
  def bulk_invalid?({:invalid, reason}, :days), do: reason in [:no_criteria, :older_than_days]
  def bulk_invalid?(_error, _field), do: false

  @doc false
  # The match fieldset is the subject of a `match` error and of "domain match on a public suffix".
  def bulk_match_error?({:invalid, reason}), do: reason in [:match, :public_suffix]
  def bulk_match_error?(_error), do: false

  @doc false
  def described_by(help_id, error, field),
    do: if(bulk_invalid?(error, field), do: help_id <> " bulk-error", else: help_id)

  attr :form, :map, required: true
  attr :error, :any, default: nil
  attr :heading, :string, required: true

  @doc false
  # The criteria form (GET = preview first). Used on the list page and, with the entered values, on
  # the preview page. Labelled inputs, the match radios in a fieldset with legend, help text and the
  # error attached with aria-describedby.
  def bulk_form(assigns) do
    ~H"""
    <form method="get" action={bulk_path()} data-form="bulk-remove" class="card bg-base-200 p-4 my-6 max-w-3xl">
      <h2 class="text-lg font-semibold mb-1">{@heading}</h2>
      <p class="text-sm text-base-content/70 mb-3">
        Remove pending registrations in bulk, for example after a flood. You see a preview first.
        Approved and rejected clients are never removed. At least one criterion is required: a host
        or domain, an age, or both.
      </p>
      <div class="mb-3">
        <label for="bulk-host" class="block text-sm font-medium mb-1">Host or domain</label>
        <input
          type="text"
          id="bulk-host"
          name="host"
          value={@form.host}
          maxlength="253"
          autocomplete="off"
          class={["input input-bordered input-sm w-full max-w-md", bulk_invalid?(@error, :host) && "input-error"]}
          aria-describedby={described_by("bulk-host-help", @error, :host)}
          aria-invalid={bulk_invalid?(@error, :host) && "true"}
        />
        <p id="bulk-host-help" class="text-xs text-base-content/70 mt-1">
          For example element.example.com or example.com. Leave empty to select by age only.
        </p>
      </div>
      <fieldset
        id="bulk-match"
        class="mb-3 border border-base-300 rounded p-3"
        aria-describedby={bulk_match_error?(@error) && "bulk-error"}
      >
        <legend class="label-text font-semibold px-1">Match</legend>
        <div class="flex flex-col gap-1">
          <div class="flex items-center gap-2">
            <input type="radio" id="bulk-match-domain" name="match" value="domain" checked={@form.match != "exact"} class="radio radio-sm" />
            <label for="bulk-match-domain" class="text-sm">Registrable domain and all its subdomains</label>
          </div>
          <div class="flex items-center gap-2">
            <input type="radio" id="bulk-match-exact" name="match" value="exact" checked={@form.match == "exact"} class="radio radio-sm" />
            <label for="bulk-match-exact" class="text-sm">Exact host only</label>
          </div>
        </div>
      </fieldset>
      <div class="mb-3">
        <label for="bulk-days" class="block text-sm font-medium mb-1">Older than (days)</label>
        <input
          type="number"
          id="bulk-days"
          name="older_than_days"
          value={@form.older_than_days}
          min="1"
          max="3650"
          class={["input input-bordered input-sm w-32", bulk_invalid?(@error, :days) && "input-error"]}
          aria-describedby={described_by("bulk-days-help", @error, :days)}
          aria-invalid={bulk_invalid?(@error, :days) && "true"}
        />
        <p id="bulk-days-help" class="text-xs text-base-content/70 mt-1">
          Optional, 1 to 3650. Combined with the host: only registrations matching both are removed.
        </p>
      </div>
      <div>
        <button type="submit" class="btn btn-sm btn-outline">Preview removal</button>
      </div>
    </form>
    """
  end

  @doc false
  def application_type_label("native"), do: "native"
  def application_type_label("web"), do: "web"
  def application_type_label(_), do: "unknown"

  @doc false
  def display_name(%{client_name: name}) when is_binary(name) and name != "", do: name
  def display_name(%{client_id: id}), do: "(unnamed client " <> id <> ")"
end
