defmodule Nebu.Admin.OAuthRegistrationsController do
  @moduledoc """
  HTTP controller for the OAuth client-registration approval page (epic oauth-broker, story
  oauth-metadata-dcr-admin-approval, AC4/AC7).

    * `GET  /admin/oauth/registrations`                       — list PENDING registrations, 50 per
      page (`?page=N`), with the real total and a "N more pending" indicator — never silently
      truncated (HTML; `Accept: application/json` returns `{"registrations": [...], "total": n,
      "page": n, "page_size": n, "total_pages": n}`)
    * `GET  /admin/oauth/registrations?logos=1`               — the same page WITH logo images
    * `GET  /admin/oauth/registrations/:client_id/approve`    — the approve CONFIRM page (story
      oauth-client-revocation, SO3: the list's Approve is a link to it; read only)
    * `POST /admin/oauth/registrations/:client_id/approve`    — approve (needs a fresh admin re-authentication
      marker and STRICT fetch metadata, SO2 / SO4: see `Nebu.Admin.OAuthAdminHelpers.gate/3`)
    * `POST /admin/oauth/registrations/:client_id/reject`     — reject (optional `reason`)
    * `GET  /admin/oauth/registrations/bulk-remove`           — read-only PREVIEW of a bulk removal
      (`host` + `match=exact|domain`, `older_than_days`; HTML only)
    * `POST /admin/oauth/registrations/bulk-remove`           — the removal (story
      oauth-dcr-abuse-hardening, AH8/AH9)

  Dynamic Client Registration is open, but EVERY registration starts `pending`; it is usable in
  authorization flows only after an admin approved it here (approval is per metadata hash — the
  row is shared by all identical registrations). There is deliberately no auto-approval.

  Both decisions are Post-Redirect-Get, CSRF-protected (`:browser` pipeline), behind
  `Nebu.Admin.Auth, :require_admin`, and race-safe: the UPDATE only touches a row that is still
  `pending`, so a second admin's decision (or a replay) never overwrites the first and writes no
  audit entry. Rejecting keeps the registration (Matrix spec: MUST NOT delete registrations);
  `approved_by` / `rejected_by` = the admin's Matrix user id.

  Every successful decision writes ONE compliance audit row through the `:compliance,
  :audit_writer` seam: action `oauth_client_approved` / `oauth_client_rejected`, target_type
  `oauth_client`, target_id = client_id, the optional rejection reason in `metadata.reason`. The
  client metadata (name, URIs, redirect URIs) is NOT part of the audit row. Decision and audit row
  are written in ONE database transaction (`Nebu.OAuth.approve_registration/3` with an `:audit`
  function): when the audit write fails the decision is ROLLED BACK (the registration stays pending),
  the error is logged and the admin sees an error flash saying nothing was changed — a decision is
  never unaudited, and never reported as a success. The rejection reason is stripped of control,
  format, private-use, surrogate and line/paragraph-separator characters (a NUL in it would make
  the jsonb audit insert fail).

  Approve has a confirm PAGE, not a JavaScript `confirm()` (SO3): `Sec-Fetch-User: ?1`, which the strict fetch
  metadata level requires, is only sent for a plain user-clicked submit. The page repeats the verified host, the
  redirect URI badges and the shared-hosting warning of the list. Reject keeps the native `confirm()` (the form
  carries `data-confirm`, wired by the external `/admin/static/assets/app.js`; CSP `script-src 'self'`; dead
  controller render, no LiveView) and, like the bulk removal, needs the STRICT fetch metadata (a scripted POST
  cannot reject; no marker: a rejection only withholds an approval); a native `confirm()` cannot
  collect text, so the reject form has an always-visible optional `reason` input. The approve audit row records
  how the fresh login was proven (`metadata.reauth`: `auth_time` | `flow`).

  ## Logos only on click (ADR-033, decision Phil 2026-10-09)

  A client's `logo_uri` is attacker-chosen. Rendering it as `<img>` would make the ADMIN's browser
  contact the registrant's host merely by opening this page (IP/User-Agent leak, blind GET probe).
  The default page therefore renders NO `<img>` and keeps the strict admin CSP (`img-src 'self'
  data:`); the logo URL is shown as text (host prominent). The "Load logos" control re-requests
  the page with `?logos=1` (per page, not sticky): only THAT response renders `<img>` (https only,
  `referrerpolicy="no-referrer"`, lazy) and only THAT response widens `img-src`, to the exact
  origins of the logos shown on that page (`Nebu.Admin.OAuthRegistrationsHTML.logo_origin/1`;
  CSP also applies to redirects, so a logo host cannot bounce the browser elsewhere). Deciding
  without ever loading a logo is fully possible — logos are informational.

  ## Bulk removal (AH8, AH9)

  After a flood the admin removes pending registrations in bulk: by host (exact) or registrable
  domain and/or by age (AND-combined, at least one). The GET is a read-only preview (match count, the
  first 20 rows, criteria in words) that stamps a snapshot `as_of` (the DATABASE clock, the time base of `created_at`) into the confirm form;
  the POST removes only rows created at or before `as_of` (a registration made after the preview is
  never swept), at most 500 per run (the flash says how many still match), and refuses an `as_of`
  that is missing, in the future or older than one hour ("preview expired"). The confirmation is the
  same native `data-confirm`. The removal is a DELETE of PENDING rows, deliberately not a bulk
  "reject": a rejection is final (guard trigger), and a deleted legitimate registration simply
  re-appears as pending on the client's next flow. Approved and rejected registrations are never
  touched. Deletion and the ONE audit row (`oauth_clients_bulk_removed`, target_type `oauth_client`,
  target_id `"bulk"`, metadata `criteria`, `as_of`, `removed`, `client_ids`; never client metadata)
  share ONE transaction (`Nebu.OAuth.bulk_remove_pending/3` with an `:audit` function): when the audit
  write fails nothing is removed. Zero matches writes no audit row. The only log line is
  `OAuth admin: bulk removal removed=<n> actor=<admin id>`: never a host, domain or client id.

  ADR-018: no domain model here; all queries live in `Nebu.OAuth.ClientStore`.
  ADR-020: the OAuth domain is reached only through its public API `Nebu.OAuth`.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  require Logger

  plug Nebu.Admin.Auth, :require_admin

  alias Nebu.Admin.OAuthAdminHelpers, as: Helpers

  @list_path "/admin/oauth/registrations"

  def index(conn, params) do
    show_logos? = params["logos"] == "1"

    {registrations, paging, load_error?} =
      case Nebu.OAuth.pending_registrations(parse_page(params["page"])) do
        {:ok, %{registrations: list} = paging} -> {Enum.map(list, &present/1), paging, false}
        {:error, _reason} -> {[], %{total: 0, page: 1, page_size: Nebu.OAuth.page_size(), total_pages: 1}, true}
      end

    case get_format(conn) do
      "json" when load_error? ->
        conn
        |> put_status(503)
        |> json(%{"error" => "The pending registrations could not be loaded."})

      "json" ->
        json(conn, %{
          "registrations" => Enum.map(registrations, &json_entry/1),
          "total" => paging.total,
          "page" => paging.page,
          "page_size" => paging.page_size,
          "total_pages" => paging.total_pages
        })

      _ ->
        conn
        # An unreadable database is NOT "nothing pending": say so instead of rendering the empty state.
        |> then(fn conn ->
          if load_error?,
            do: put_flash(conn, :error, "The pending registrations could not be loaded. Please try again."),
            else: conn
        end)
        |> assign(:load_error, load_error?)
        |> assign(:registrations, registrations)
        |> assign(:total, paging.total)
        |> assign(:page, paging.page)
        |> assign(:page_size, paging.page_size)
        |> assign(:total_pages, paging.total_pages)
        |> assign(:show_logos, show_logos?)
        |> allow_logo_origins(show_logos?, registrations)
        |> assign(:oauth_enabled, Nebu.OAuth.config().enabled)
        |> assign(:page_title, "Pending OAuth Clients")
        |> assign(:active_nav, "oauth-pending-clients")
        |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
        |> put_layout(html: {Nebu.Admin.Layouts, :live})
        |> render(:index)
    end
  end

  # ── bulk removal (AH8, AH9) ─────────────────────────────────────────────────

  def bulk_preview(conn, params) do
    form = bulk_form(params)

    # The snapshot is the DATABASE clock (M2): `created_at` is a database timestamp, so an application
    # node whose clock differs must not decide which rows a later POST sweeps.
    {as_of, {state, error}} =
      case Nebu.OAuth.bulk_remove_snapshot() do
        {:ok, as_of} ->
          {as_of, preview_state(bulk_criteria(form), as_of)}

        {:error, reason} ->
          Logger.error("OAuth admin: bulk removal preview failed: #{error_type(reason)}")
          {nil, {nil, :storage}}
      end

    conn
    |> assign(:form, form)
    |> assign(:preview, state)
    |> assign(:error, error)
    |> assign(:as_of, as_of && DateTime.to_iso8601(as_of))
    |> assign(:oauth_enabled, Nebu.OAuth.config().enabled)
    |> assign(:page_title, "Remove pending registrations")
    |> assign(:active_nav, "oauth-pending-clients")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:bulk_preview)
  end

  def bulk_remove(conn, params) do
    case Helpers.gate(conn, :click, @list_path) do
      {:ok, conn, _} -> do_bulk_remove(conn, params)
      {:halt, conn} -> conn
    end
  end

  defp do_bulk_remove(conn, params) do
    form = bulk_form(params)

    with {:actor, actor} when is_binary(actor) <- {:actor, actor_id(conn)},
         {:as_of, {:ok, as_of}} <- {:as_of, parse_as_of(params["as_of"])} do
      audit = fn ids -> write_bulk_audit(actor, form, as_of, ids) end

      case Nebu.OAuth.bulk_remove_pending(bulk_criteria(form), as_of, audit: audit) do
        {:ok, %{removed: 0}} ->
          conn
          |> put_flash(:info, "No pending registration matched; nothing was removed.")
          |> redirect(to: @list_path)

        {:ok, %{removed: removed, remaining: remaining}} ->
          Logger.info("OAuth admin: bulk removal removed=#{removed} actor=#{actor}")

          conn
          |> put_flash(:info, bulk_success_text(removed, remaining))
          |> redirect(to: @list_path)

        {:error, {:invalid_criteria, _reason}} ->
          conn
          |> put_flash(:error, "The removal criteria are invalid. Nothing was removed.")
          |> redirect(to: @list_path)

        {:error, {:audit, reason}} ->
          # Deletion and audit row share one transaction: the removal was rolled back.
          Logger.error(
            "OAuth admin: bulk removal audit entry could not be written, removal rolled back: #{error_type(reason)}"
          )

          conn
          |> put_flash(
            :error,
            "The removal was not saved because its audit log entry could not be written; nothing was removed. " <>
              "Please try again or contact the operator."
          )
          |> redirect(to: @list_path)

        {:error, other} ->
          Logger.error("OAuth admin: bulk removal could not be saved: #{error_type(other)}")

          conn
          |> put_flash(:error, "The pending registrations could not be removed; nothing was removed. Please try again.")
          |> redirect(to: @list_path)
      end
    else
      {:actor, _} ->
        conn
        |> put_flash(:error, "Could not determine the admin user id.")
        |> redirect(to: @list_path)

      {:as_of, :storage} ->
        conn
        |> put_flash(:error, "The preview could not be checked; nothing was removed. Please try again.")
        |> redirect(to: @list_path)

      {:as_of, :expired} ->
        conn
        |> put_flash(:error, "The preview expired. Preview the removal again; nothing was removed.")
        |> redirect(to: @list_path)
    end
  end

  defp preview_state(criteria, as_of) do
    case Nebu.OAuth.bulk_remove_preview(criteria, as_of) do
      {:ok, %{count: count, rows: rows}} ->
        {%{count: count, rows: Enum.map(rows, &present/1)}, nil}

      {:error, {:invalid_criteria, reason}} ->
        {nil, {:invalid, reason}}

      {:error, reason} ->
        Logger.error("OAuth admin: bulk removal preview failed: #{error_type(reason)}")
        {nil, :storage}
    end
  end

  # The raw form values (strings), preserved on the re-rendered preview.
  defp bulk_form(params) do
    %{
      host: string_param(params["host"]),
      match: match_param(params["match"]),
      older_than_days: string_param(params["older_than_days"])
    }
  end

  defp string_param(value) when is_binary(value), do: value
  defp string_param(_), do: ""

  # Absent = the default "domain"; an unknown mode is kept as "invalid" (the store refuses it, the
  # arbitrary value is never echoed).
  defp match_param(value) when value in ["exact", "domain"], do: value
  defp match_param(value) when value in [nil, ""], do: "domain"
  defp match_param(_), do: "invalid"

  defp bulk_criteria(%{host: host, match: match, older_than_days: days}) do
    %{host: host, match: bulk_match(match), older_than_days: days}
  end

  defp bulk_match("exact"), do: :exact
  defp bulk_match("domain"), do: :domain
  defp bulk_match(_), do: :invalid

  # as_of: ISO 8601, not in the future, at most one hour old, both judged on the DATABASE clock (M2).
  defp parse_as_of(value) when is_binary(value) do
    with {:ok, as_of, _offset} <- DateTime.from_iso8601(value),
         {:age, {:ok, age}} <- {:age, Nebu.OAuth.bulk_remove_snapshot_age_us(as_of)} do
      if age >= 0 and age <= 3_600_000_000, do: {:ok, as_of}, else: :expired
    else
      {:age, {:error, _}} -> :storage
      _ -> :expired
    end
  end

  defp parse_as_of(_), do: :expired

  defp bulk_success_text(1, 0), do: "1 pending registration removed."
  defp bulk_success_text(removed, 0), do: "#{removed} pending registrations removed."
  defp bulk_success_text(removed, remaining), do: "#{removed} removed, #{remaining} still match. Run the removal again."

  # ONE audit row for the whole run (never the client metadata). Same writer seam as `write_audit/4`.
  defp write_bulk_audit(actor, form, as_of, ids) do
    # "host" is what the admin typed, "domain" the EFFECTIVE registrable domain that was swept (a
    # `domain` match of `app.example.com` removes everything of `example.com`), "older_than_days" the
    # parsed age.
    effective =
      case Nebu.OAuth.bulk_remove_criteria(bulk_criteria(form)) do
        {:ok, c} -> c
        _ -> %{domain: nil, days: nil}
      end

    metadata = %{
      "criteria" => %{
        "host" => blank_to_nil(String.downcase(String.trim(form.host))),
        "match" => form.match,
        "domain" => effective.domain,
        "older_than_days" => effective.days
      },
      "as_of" => DateTime.to_iso8601(as_of),
      "removed" => length(ids),
      "client_ids" => ids
    }

    try do
      case audit_writer().log(actor, "oauth_clients_bulk_removed", "oauth_client", "bulk", metadata, "success", nil) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, _} = error -> error
        other -> {:error, other}
      end
    rescue
      e -> {:error, {:raised, e.__struct__}}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # GET: the approve confirm page (SO3). Read only; a decided / unknown client goes back to the list.
  def approve_confirm(conn, %{"client_id" => client_id} = params) do
    case Nebu.OAuth.registration(client_id) do
      %{status: "pending"} = row ->
        client = present(row)

        conn
        |> assign(:client, client)
        |> assign(:show_logos, params["logos"] == "1")
        |> assign(:page, parse_page(params["page"]))
        |> assign(:reauth_fresh, match?({:ok, _}, Nebu.Admin.Auth.reauth_fresh(conn, @list_path <> "/" <> Helpers.seg(client_id) <> "/approve")))
        |> assign(:revoked_same_host, revoked_same_host(client))
        |> assign(:approve_path, @list_path <> "/" <> Helpers.seg(client_id) <> "/approve")
        |> assign(:back_path, return_path(params))
        |> assign(:oauth_enabled, Nebu.OAuth.config().enabled)
        |> assign(:page_title, "Approve OAuth client")
        |> assign(:active_nav, "oauth-pending-clients")
        |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
        |> put_layout(html: {Nebu.Admin.Layouts, :live})
        |> render(:approve_confirm)

      _ ->
        conn
        |> put_flash(:error, "This registration is unknown or has already been decided.")
        |> redirect(to: return_path(params))
    end
  end

  # L-3: how many clients of this verified host were revoked before (`:unknown` when it cannot be read: say so)
  defp revoked_same_host(%{client_uri: uri}) do
    case Nebu.OAuth.revoked_count_for_host(Nebu.Admin.OAuthRegistrationsHTML.uri_host(uri)) do
      {:ok, n} -> n
      {:error, _} -> :unknown
    end
  end

  def approve(conn, %{"client_id" => client_id} = params) do
    case Helpers.gate(conn, :marker, @list_path <> "/" <> Helpers.seg(client_id) <> "/approve") do
      {:ok, conn, kind} -> decide(conn, client_id, :approve, nil, return_path(params), %{"reauth" => kind})
      {:halt, conn} -> conn
    end
  end

  def reject(conn, %{"client_id" => client_id} = params) do
    case Helpers.gate(conn, :click, @list_path) do
      {:ok, conn, _} -> decide(conn, client_id, :reject, Nebu.OAuth.normalize_reason(params["reason"]), return_path(params), %{})
      {:halt, conn} -> conn
    end
  end

  # ── paging / logos ──────────────────────────────────────────────────────────

  # `?page=N`: anything that is not a positive integer is page 1 (the store clamps too-large pages).
  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  # After a decision the admin returns to the page (and logo mode) they came from; the forms carry
  # both as hidden fields. Only sanitised values are ever put into the Location header.
  defp return_path(params) do
    page = parse_page(params["page"])
    query = if(page > 1, do: ["page=#{page}"], else: []) ++ if(params["logos"] == "1", do: ["logos=1"], else: [])

    case query do
      [] -> @list_path
      parts -> @list_path <> "?" <> Enum.join(parts, "&")
    end
  end

  # ONLY a `?logos=1` response widens `img-src` — to the exact origins of the logos on this page
  # (the template renders `<img>` for exactly the rows whose `logo_origin/1` is non-nil). No
  # origins => the strict policy stays untouched.
  defp allow_logo_origins(conn, false, _registrations), do: conn

  defp allow_logo_origins(conn, true, registrations) do
    origins =
      registrations
      |> Enum.map(&Nebu.Admin.OAuthRegistrationsHTML.logo_origin(&1.logo_uri))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case {origins, get_resp_header(conn, "content-security-policy")} do
      {[], _} ->
        conn

      {_, [csp | _]} ->
        widened = String.replace(csp, "img-src 'self' data:", "img-src 'self' data: " <> Enum.join(origins, " "))
        put_resp_header(conn, "content-security-policy", widened)

      _ ->
        conn
    end
  end

  # ── decision (race-safe, audited) ───────────────────────────────────────────

  defp decide(conn, client_id, action, reason, back, extra) do
    case Helpers.actor_id(conn) do
      nil ->
        conn
        |> put_flash(:error, "Could not determine the admin user id.")
        |> redirect(to: back)

      actor ->
        audit = fn -> write_audit(actor, action, client_id, reason, extra) end

        result =
          case action do
            :approve -> Nebu.OAuth.approve_registration(client_id, actor, audit: audit)
            :reject -> Nebu.OAuth.reject_registration(client_id, actor, audit: audit)
          end

        case result do
          :ok ->
            Logger.info("OAuth admin: client #{past(action)} client_id=#{client_id}")

            # one fresh sign-in, one decision (Kassandra M-1): an approval consumes its marker
            conn = if action == :approve, do: Nebu.Admin.Auth.consume_reauth(conn), else: conn

            conn
            |> put_flash(:info, "#{client_label(client_id)} #{past(action)}.")
            |> redirect(to: back)

          {:error, :not_pending} ->
            conn
            |> put_flash(:error, "This registration is unknown or has already been decided.")
            |> redirect(to: back)

          {:error, {:audit, reason}} ->
            # Decision and audit row share one transaction: the decision was rolled back.
            Logger.error(
              "OAuth admin: audit entry for client #{past(action)} client_id=#{client_id} could not be written, " <>
                "decision rolled back: #{error_type(reason)}"
            )

            conn
            |> put_flash(
              :error,
              "The decision was not saved because its audit log entry could not be written. " <>
                "Nothing was changed; the registration is still pending. Please try again or contact the operator."
            )
            |> redirect(to: back)

          {:error, other} ->
            # Type / SQLSTATE only: a driver error carries the failing row (registrant IP, metadata).
            Logger.error(
              "OAuth admin: decision (#{action}) for client_id=#{client_id} could not be saved: #{error_type(other)}"
            )

            conn
            |> put_flash(:error, "The decision could not be saved. Please try again.")
            |> redirect(to: back)
        end
    end
  end

  defp error_type(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp error_type(%{__struct__: struct}), do: inspect(struct)
  defp error_type(reason) when is_atom(reason), do: inspect(reason)
  defp error_type(_reason), do: "unexpected error"

  # `Client "<name>"` (name shortened to keep the flash readable), or `Client <id>` when unnamed.
  # HEEx escapes the flash text; new registrations cannot carry control/bidi characters in the name.
  defp client_label(client_id) do
    case Nebu.OAuth.registration(client_id) do
      %{metadata: %{"client_name" => name}} when is_binary(name) and name != "" ->
        "Client \"#{String.slice(name, 0, 60)}#{if String.length(name) > 60, do: "…"}\""

      _ ->
        "Client #{client_id}"
    end
  end

  defp past(:approve), do: "approved"
  defp past(:reject), do: "rejected"

  # ── audit (AC7): never the client metadata ──────────────────────────────────

  # `extra`: the approve row records how the fresh login was proven (`reauth`).
  defp write_audit(actor, action, client_id, reason, extra) do
    {name, metadata} =
      case action do
        :approve -> {"oauth_client_approved", extra}
        :reject -> {"oauth_client_rejected", if(reason, do: %{"reason" => reason}, else: %{})}
      end

    Helpers.write_audit(actor, name, client_id, metadata)
  end

  defp audit_writer, do: Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

  defp actor_id(conn), do: Helpers.actor_id(conn)

  # ── presentation ────────────────────────────────────────────────────────────

  defp present(%{client_id: id, metadata: meta, application_type: app, created_at: created_at}) do
    %{
      client_id: id,
      client_name: string_field(meta, "client_name"),
      client_uri: string_field(meta, "client_uri"),
      logo_uri: string_field(meta, "logo_uri"),
      redirect_uris: list_field(meta, "redirect_uris"),
      application_type: app,
      created_at: created_at
    }
  end

  defp json_entry(r) do
    %{
      "client_id" => r.client_id,
      "client_name" => r.client_name,
      "client_uri" => r.client_uri,
      "logo_uri" => r.logo_uri,
      "redirect_uris" => r.redirect_uris,
      "application_type" => r.application_type,
      "created_at" => r.created_at && format_dt(r.created_at)
    }
  end

  defp string_field(meta, key) do
    case Map.get(meta, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp list_field(meta, key) do
    case Map.get(meta, key) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp format_dt(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp format_dt(%NaiveDateTime{} = dt), do: dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  defp format_dt(_), do: nil
end
