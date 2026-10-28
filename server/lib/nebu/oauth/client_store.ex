defmodule Nebu.OAuth.ClientStore do
  @moduledoc """
  Persistence of OAuth client registrations (`oauth_clients`, migration 000040) — epic
  oauth-broker, story oauth-metadata-dcr-admin-approval.

  ADR-018: SQL is written inline here (no ORM, no Ecto schema, no repository layer).
  ADR-020 (cluster safety): no application-level locks and no process state. Dedup is made atomic
  by `INSERT ... ON CONFLICT (metadata_hash) DO NOTHING`, decisions by
  `UPDATE ... WHERE status = 'pending'` with a returned-row check, so concurrent requests on any
  node of the cluster converge on one row / one decision.

  `approved` / `rejected` / `revoked` registrations are NEVER deleted (Matrix spec: a server MUST NOT delete a
  registration with an active session) — rejecting only sets `status = 'rejected'`, withdrawing an approved
  client (`revoke/3`, story oauth-client-revocation, migration 000046) only sets `status = 'revoked'`. The only
  `DELETE`s in this module are `purge_expired_pending/1` and, as the second DELETE, the admin's bulk
  removal `bulk_delete_pending/3` (story oauth-dcr-abuse-hardening, AH8), both restricted to
  `status = 'pending'` (pending rows have no session); the runtime role's row level security
  (migration 000040) enforces the same restriction in the database.

  Pending rows are bounded because registration is unauthenticated: `register/1` refuses NEW
  metadata (`{:error, :capacity}`; dedup hits are unaffected by every cap) when
    * the global pending cap is reached (`Nebu.OAuth.Config.pending_limits/0`, server_config), or
    * the same SOURCE (`:source_key`, `Nebu.OAuth.SourceKey`: IPv4 /32, IPv6 /64) already has
      `oauth_pending_host_cap` pending rows with the same REGISTRABLE DOMAIN of the `client_uri` host
      (`client_domain`, `Nebu.OAuth.PublicSuffix`; AH1 — an attacker filling its own slots for
      `element.company.com` no longer blocks the real client, which registers from another source;
      nothing is ever evicted), or
    * the source already has #{100} pending rows over all domains (AH2, built-in).
  `purge_expired_pending/1` removes pending rows older than the TTL.

  `created_from_ip` / `user_agent` / `source_key` of the first registrant are kept for abuse triage
  and the caps ONLY while the row is pending: approve/reject set all three to NULL (data
  minimisation, ADR-033 "Retention"; a CHECK of migration 000044 pins it for `source_key`).

  `bulk_preview/2` and `bulk_delete_pending/3` serve the admin "Remove pending registrations" action
  (AH8, AH9): criteria (host exact / registrable domain, age) are AND-combined, only rows with
  `created_at <= as_of` (the preview snapshot) and `status = 'pending'` are touched, at most #{500}
  per call, in one transaction together with the caller's audit function.

  `approve/3` / `reject/3` can run a caller-supplied `:audit` function in the SAME database
  transaction as the decision: when it does not return `:ok` the decision is rolled back, so a
  decision is never unaudited.

  `revoke/3` withdraws an APPROVED client in ONE transaction (CR4): the status UPDATE, the teardown of every
  session / device of the client (through the `Nebu.Matrix` facade, same transaction), the client's unused
  codes, authorize and consent requests, and the caller's `:audit` function; a revocation is final for that
  metadata hash (identical metadata maps to the revoked row, never to a new pending one).

  Approval is per METADATA HASH (one row per hash), not per `client_id`: all registrations with
  identical metadata share the row, its `client_id` and its status. A re-registration of a decided
  client returns the existing row unchanged (status is never reset to `pending`).
  """

  require Logger

  alias Nebu.OAuth.{Config, PublicSuffix, Registration}

  @pending_source_cap 100

  # The caps are part of the INSERT itself (one statement): the row is only inserted while fewer than
  # `$9` pending rows exist overall AND fewer than `$10` pending rows share the registrable domain
  # `$11` AND the source `$12` (a NULL domain / source counts the NULL rows; written as `(p IS NULL AND
  # col IS NULL) OR col = p` instead of IS NOT DISTINCT FROM so the partial btree index of migration
  # 000044 stays usable)
  # AND, for a known source, fewer than `$13` pending rows of that source exist over all domains.
  # A dedup hit conflicts on metadata_hash (DO NOTHING) and is found by the follow-up SELECT,
  # so it is answered even when a cap is reached. READ COMMITTED does not
  # serialise concurrent counts, so N in-flight registrations can overshoot the cap by at most N-1
  # (bounded by DB pool size x nodes and by the registration rate limits) — acceptable for a
  # soft abuse cap, and cheaper than a table lock on a public endpoint.
  @sql_insert """
  INSERT INTO oauth_clients
    (client_id, metadata, metadata_hash, application_type, token_endpoint_auth_method,
     client_host, created_from_ip, user_agent, client_domain, source_key)
  SELECT $1::text, $2::jsonb, $3::text, $4::text, $5::text, $6::text, $7::text, $8::text,
         $11::text, $12::text
  WHERE (SELECT count(*) FROM oauth_clients WHERE status = 'pending') < $9::bigint
    AND (SELECT count(*) FROM oauth_clients
         WHERE status = 'pending'
           AND (($11::text IS NULL AND client_domain IS NULL) OR client_domain = $11::text)
           AND (($12::text IS NULL AND source_key IS NULL) OR source_key = $12::text)) < $10::bigint
    AND ($12::text IS NULL
         OR (SELECT count(*) FROM oauth_clients
             WHERE status = 'pending' AND source_key = $12::text) < $13::bigint)
  ON CONFLICT (metadata_hash) DO NOTHING
  """

  @sql_by_hash "SELECT client_id, status, metadata FROM oauth_clients WHERE metadata_hash = $1"
  # (identical SELECT: the dedup lookup that runs BEFORE the strict registration rate limit)

  @sql_by_id """
  SELECT client_id, status, metadata, application_type, token_endpoint_auth_method,
         approved_by, approved_at, rejected_by, rejected_at, created_at, client_host,
         revoked_by, revoked_at, revoked_reason
  FROM oauth_clients WHERE client_id = $1
  """

  @page_size 50

  @sql_pending_count "SELECT count(*) FROM oauth_clients WHERE status = 'pending'"

  @sql_pending_page """
  SELECT client_id, metadata, application_type, created_at
  FROM oauth_clients
  WHERE status = 'pending'
  ORDER BY created_at DESC, client_id
  LIMIT $1 OFFSET $2
  """

  # Purge of expired PENDING rows. Batched (bounded statement time) and `FOR UPDATE SKIP LOCKED`, so
  # purgers on several nodes (or a concurrent admin decision on the same row) never block each other
  # and a row being approved/rejected right now is skipped. The outer `status = 'pending'` is
  # re-checked after the row lock, so a row that was decided in the meantime is never deleted.
  @sql_purge_pending """
  DELETE FROM oauth_clients
  WHERE status = 'pending'
    AND client_id IN (
      SELECT client_id FROM oauth_clients
      WHERE status = 'pending' AND created_at < NOW() - ($1::int * INTERVAL '1 day')
      ORDER BY created_at
      LIMIT $2
      FOR UPDATE SKIP LOCKED
    )
  """

  @purge_batch 1000
  @purge_max_batches 20

  @sql_approve """
  UPDATE oauth_clients
  SET status = 'approved', approved_by = $2, approved_at = NOW(), created_from_ip = NULL, user_agent = NULL,
      source_key = NULL
  WHERE client_id = $1 AND status = 'pending'
  RETURNING client_id
  """

  @sql_reject """
  UPDATE oauth_clients
  SET status = 'rejected', rejected_by = $2, rejected_at = NOW(), created_from_ip = NULL, user_agent = NULL,
      source_key = NULL
  WHERE client_id = $1 AND status = 'pending'
  RETURNING client_id
  """

  @sql_revoke """
  UPDATE oauth_clients
  SET status = 'revoked', revoked_by = $2, revoked_at = NOW(), revoked_reason = $3
  WHERE client_id = $1 AND status = 'approved'
  RETURNING client_id
  """

  # `used_at` NULL -> NOT NULL is the only UPDATE the oauth_codes guard trigger allows (migration 000041)
  @sql_use_codes "UPDATE oauth_codes SET used_at = now() WHERE client_id = $1 AND used_at IS NULL"
  @sql_delete_requests "DELETE FROM oauth_authz_requests WHERE client_id = $1"
  # P3 (migration 000045): the FK cascades only a client DELETE, which never happens to a revoked row
  @sql_delete_consents "DELETE FROM oauth_consent_requests WHERE client_id = $1"

  @sql_approved_count "SELECT count(*) FROM oauth_clients WHERE status = 'approved'"
  @sql_approved_page """
  SELECT client_id, metadata, application_type, client_host, approved_by, approved_at, last_used_at
  FROM oauth_clients
  WHERE status = 'approved'
  ORDER BY approved_at DESC, client_id
  LIMIT $1 OFFSET $2
  """

  @sql_revoked_count "SELECT count(*) FROM oauth_clients WHERE status = 'revoked'"
  @sql_revoked_page """
  SELECT client_id, metadata, application_type, client_host, revoked_by, revoked_at, revoked_reason
  FROM oauth_clients
  WHERE status = 'revoked'
  ORDER BY revoked_at DESC, client_id
  LIMIT $1 OFFSET $2
  """

  @doc """
  Registers (or re-finds) a client for already validated/normalized metadata
  (see `Nebu.OAuth.Registration.validate/1`).

  Takes `%{metadata:, hash:, application_type:, token_endpoint_auth_method:}` plus optional
  `:ip` / `:user_agent` (audit fields of the FIRST registration). Returns
  `{:ok, %{client_id:, status:, metadata:, created?: boolean}}`; a second identical registration
  (any node, any time, also concurrent) returns the SAME `client_id` and the CURRENT status.

  A registration of NEW metadata while the global pending cap, the (registrable domain, source)
  cap or the per-source cap is reached is `{:error, :capacity}` (the caller answers 503 +
  `Retry-After`); a dedup hit never is. The caps are `Nebu.OAuth.Config.pending_limits().cap` /
  `.host_cap` and the built-in #{@pending_source_cap} unless `:pending_cap` / `:pending_host_cap` /
  `:pending_source_cap` are given. The host is `:client_host` and its registrable domain
  `:client_domain` (both as returned by `Nebu.OAuth.Registration.validate/1`), else derived from
  `metadata["client_uri"]`. `:source_key` (`Nebu.OAuth.SourceKey.for_conn/1`) is the source; without
  one the per-source condition is skipped (and NULL-source rows are counted per domain).

  Metadata that PostgreSQL refuses as DATA (SQLSTATE class 22, e.g. a NUL character that jsonb
  cannot store) is the caller's fault, not an outage: `{:error, :invalid_metadata}`. Every other
  failure is `{:error, reason}` (storage unavailable).
  """
  @spec register(map()) :: {:ok, map()} | {:error, :invalid_metadata | :capacity | term()}
  def register(%{metadata: metadata, hash: hash} = attrs) do
    client_id = generate_client_id()
    limits = Config.pending_limits()
    cap = Map.get(attrs, :pending_cap) || limits.cap
    host_cap = Map.get(attrs, :pending_host_cap) || limits.host_cap
    source_cap = Map.get(attrs, :pending_source_cap) || @pending_source_cap
    host = Map.get(attrs, :client_host) || host_of(metadata)

    params = [
      client_id,
      metadata,
      hash,
      Map.fetch!(attrs, :application_type),
      Map.fetch!(attrs, :token_endpoint_auth_method),
      host,
      Map.get(attrs, :ip),
      truncate(Map.get(attrs, :user_agent), 512),
      cap,
      host_cap,
      Map.get(attrs, :client_domain) || domain_of(host),
      Map.get(attrs, :source_key),
      source_cap
    ]

    with {:ok, %{num_rows: inserted}} <- query(@sql_insert, params),
         {:ok, %{rows: [[id, status, stored]]}} <- query(@sql_by_hash, [hash]) do
      {:ok, %{client_id: id, status: status, metadata: decode(stored), created?: inserted == 1}}
    else
      # Neither inserted nor found by hash: the cap refused a NEW registration (or, in a
      # vanishingly small window, the conflicting pending row was purged between the two
      # statements — also "try again later").
      {:ok, %{rows: []}} -> {:error, :capacity}
      {:error, %Postgrex.Error{postgres: %{pg_code: "22" <> _}}} -> {:error, :invalid_metadata}
      {:error, %DBConnection.EncodeError{}} -> {:error, :invalid_metadata}
      {:error, _} = error -> error
    end
  end

  @doc """
  Looks a registration up by its metadata hash WITHOUT creating anything: `{:ok, %{client_id:,
  status:, metadata:}}` for a known one, `{:ok, nil}` for unknown metadata, `{:error, reason}` when
  the database could not be read. Used to tell a dedup hit (cheap, loosely rate limited) from a NEW
  registration (strictly rate limited) before any bucket of the strict family is charged.
  """
  @spec find_by_hash(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def find_by_hash(hash) when is_binary(hash) do
    case query(@sql_by_hash, [hash]) do
      {:ok, %{rows: [[id, status, stored]]}} -> {:ok, %{client_id: id, status: status, metadata: decode(stored)}}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @doc "Fetches one registration by `client_id`, or `nil` (also when the database cannot be read; see `fetch_by_client_id/1`)."
  @spec get_by_client_id(String.t()) :: map() | nil
  def get_by_client_id(client_id) when is_binary(client_id) do
    case fetch_by_client_id(client_id) do
      {:ok, row} -> row
      {:error, _} -> nil
    end
  end

  @doc """
  The claimed `client_name` of every client in `client_ids`, in ONE query (story oauth-account-management,
  review cycle 1 m7: the account page's device list names the OAuth app of each device):
  `{:ok, %{client_id => name}}` (clients without a name, and unknown ids, are absent) or
  `{:error, reason}` (the caller simply shows no names). At most 500 ids are looked up.
  """
  @spec client_names([String.t()]) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def client_names([]), do: {:ok, %{}}

  def client_names(client_ids) when is_list(client_ids) do
    ids = client_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.take(500)

    case query("SELECT client_id, metadata FROM oauth_clients WHERE client_id = ANY($1)", [ids]) do
      {:ok, %{rows: rows}} ->
        {:ok, for([id, meta] <- rows, name = decode(meta)["client_name"], is_binary(name) and name != "", into: %{}, do: {id, name})}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The DEDUPED IDENTITY of a client (story oauth-authorize-freshness, FR11, oracle correction 2): clients
  re-register through DCR, so the same app can appear under a NEW `client_id` (a metadata change yields a
  new hash and row). Two registrations are "the same app" when they share this identity: the normalized
  `client_uri` (lower-case scheme and host, the default port, the fragment and any trailing `/` of the
  path dropped) plus the SORTED, de-duplicated `redirect_uris`. One query.

  `{:ok, %{client_uri: String.t(), redirect_uris: [String.t()]}}`, `{:ok, nil}` when the client is unknown
  or has no usable `client_uri` (then only an equal `client_id` counts as the same app), or `{:error,
  reason}` when the database cannot be read.
  """
  @spec client_identity(String.t()) :: {:ok, %{client_uri: String.t(), redirect_uris: [String.t()]} | nil} | {:error, term()}
  def client_identity(client_id) when is_binary(client_id) do
    case query("SELECT metadata FROM oauth_clients WHERE client_id = $1", [client_id]) do
      {:ok, %{rows: [[meta]]}} ->
        meta = decode(meta)

        case normalize_client_uri(meta["client_uri"]) do
          nil -> {:ok, nil}
          uri -> {:ok, %{client_uri: uri, redirect_uris: meta["redirect_uris"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()}}
        end

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, _} = error ->
        error

      other ->
        {:error, {:unexpected_result, other}}
    end
  end

  defp normalize_client_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme = String.downcase(scheme)
        port = if parsed.port in [nil, URI.default_port(scheme)], do: "", else: ":#{parsed.port}"
        path = String.trim_trailing(parsed.path || "", "/")
        query = if parsed.query, do: "?" <> parsed.query, else: ""
        "#{scheme}://#{String.downcase(host)}#{port}#{path}#{query}"

      _ ->
        nil
    end
  end

  defp normalize_client_uri(_uri), do: nil

  @doc """
  Error-aware lookup by `client_id` (story oauth-authorize-idp-delegation-code, AC2.3):
  `{:ok, row}` for a known registration (any status), `{:ok, nil}` for an unknown one, and
  `{:error, reason}` when the database could not be read — the authorize endpoint answers the
  latter with a 503 page, never with "unknown client".
  """
  @spec fetch_by_client_id(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_by_client_id(client_id) when is_binary(client_id) do
    case query(@sql_by_id, [client_id]) do
      {:ok, %{rows: [[id, status, meta, app, auth, a_by, a_at, r_by, r_at, c_at, host, v_by, v_at, v_reason]]}} ->
        {:ok,
         %{
           client_id: id,
           status: status,
           metadata: decode(meta),
           application_type: app,
           token_endpoint_auth_method: auth,
           approved_by: a_by,
           approved_at: a_at,
           rejected_by: r_by,
           rejected_at: r_at,
           created_at: c_at,
           client_host: host,
           revoked_by: v_by,
           revoked_at: v_at,
           revoked_reason: v_reason
         }}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, _} = error ->
        error

      other ->
        {:error, {:unexpected_result, other}}
    end
  end

  @doc """
  Touches `last_used_at` after a successful token grant (story oauth-token-endpoint, T30), at most
  once per hour per client (the throttle is in SQL; allowed on decided rows by the 000040 guard
  trigger). Best effort: `:ok` or `{:error, reason}`, never raises.
  """
  @spec touch_last_used(String.t()) :: :ok | {:error, term()}
  def touch_last_used(client_id) when is_binary(client_id) do
    case query(
           "UPDATE oauth_clients SET last_used_at = now() " <>
             "WHERE client_id = $1 AND (last_used_at IS NULL OR last_used_at < now() - interval '1 hour')",
           [client_id]
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  One page of the PENDING registrations, newest first, plus the totals:

      {:ok, %{registrations: [%{client_id:, metadata:, application_type:, created_at:}],
              total: non_neg_integer, page: pos_integer, page_size: 50, total_pages: pos_integer}}

  `page` is 1-based; a page beyond the last (e.g. rows were decided meanwhile) is clamped to the
  last page, a non-positive/invalid one to the first. The list is never truncated: `total` is the
  real number of pending rows, so a UI can always say how many more there are. `{:error, reason}`
  when the database could not be read (callers MUST surface that — an empty list means "nothing
  pending", not "unknown").
  """
  @spec get_pending_registrations(term()) :: {:ok, map()} | {:error, term()}
  def get_pending_registrations(page \\ 1) do
    with {:ok, %{rows: [[total]]}} <- query(@sql_pending_count, []),
         page = clamp_page(page, total),
         {:ok, %{rows: rows}} <- query(@sql_pending_page, [@page_size, (page - 1) * @page_size]) do
      {:ok,
       %{
         registrations:
           Enum.map(rows, fn [id, meta, app, created_at] ->
             %{client_id: id, metadata: decode(meta), application_type: app, created_at: created_at}
           end),
         total: total,
         page: page,
         page_size: @page_size,
         total_pages: total_pages(total)
       }}
    else
      {:error, reason} ->
        Logger.error("OAuth.ClientStore: could not list pending registrations: #{error_type(reason)}")
        {:error, reason}

      other ->
        Logger.error("OAuth.ClientStore: unexpected pending list result: #{error_type(other)}")
        {:error, :unexpected_result}
    end
  end

  @doc "The fixed page size of the pending / approved / revoked lists."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc """
  One page of the APPROVED clients, newest approval first (story oauth-client-revocation, CR7):
  `{:ok, %{clients: [%{client_id:, metadata:, application_type:, client_host:, approved_by:, approved_at:,
  last_used_at:}], total:, page:, page_size:, total_pages:}}` (paging as `get_pending_registrations/1`) or
  `{:error, reason}`.
  """
  @spec get_approved_clients(term()) :: {:ok, map()} | {:error, term()}
  def get_approved_clients(page \\ 1) do
    paged(@sql_approved_count, @sql_approved_page, page, fn [id, meta, app, host, by, at, used] ->
      %{client_id: id, metadata: decode(meta), application_type: app, client_host: host, approved_by: by, approved_at: at, last_used_at: used}
    end)
  end

  @doc "One page of the REVOKED clients, newest revocation first; like `get_approved_clients/1` with `revoked_by` / `revoked_at` / `revoked_reason`."
  @spec get_revoked_clients(term()) :: {:ok, map()} | {:error, term()}
  def get_revoked_clients(page \\ 1) do
    paged(@sql_revoked_count, @sql_revoked_page, page, fn [id, meta, app, host, by, at, reason] ->
      %{client_id: id, metadata: decode(meta), application_type: app, client_host: host, revoked_by: by, revoked_at: at, revoked_reason: reason}
    end)
  end

  @doc """
  The number of REVOKED clients that stated the same verified `client_host` (story oauth-client-revocation, L-3): the
  approve confirm page warns when a registration under a host the admin already withdrew a client from looks clean
  (changed metadata is a new hash). `{:ok, n}` or `{:error, reason}`; a nil / empty host is `{:ok, 0}`.
  """
  @spec revoked_count_for_host(String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoked_count_for_host(host) when is_binary(host) and host != "" do
    case query("SELECT count(*) FROM oauth_clients WHERE status = 'revoked' AND client_host = $1", [String.downcase(host)]) do
      {:ok, %{rows: [[n]]}} -> {:ok, n}
      {:error, _} = error -> error
      _ -> {:error, :unexpected_result}
    end
  end

  def revoked_count_for_host(_host), do: {:ok, 0}

  # Story legacy-sso-redirect-confirmation (G3-3, D6 / security review SEC #1): ONE bounded query (500 ms, the
  # `Nebu.OAuth.Config` idiom) for the https redirect URIs of APPROVED clients on one host. The SQL expands the jsonb
  # array `metadata->'redirect_uris'` (production stores an object-typed jsonb; any other shape contributes nothing)
  # and narrows by host with an ESCAPED `LIKE` (a `%` / `_` of the host is never a wildcard) that accepts `https://<host>` only
  # followed by the end or one of `/ : ? #`; `ORDER BY` makes the `LIMIT 50` deterministic; the caller
  # (`Nebu.OAuth.trusted_redirect_url?/2`) compares origin and path exactly. At most 50 URIs (more is fail closed).
  @sql_approved_redirect_uris "SELECT u FROM oauth_clients c " <>
                                "CROSS JOIN LATERAL jsonb_array_elements_text(" <>
                                "CASE WHEN jsonb_typeof(c.metadata->'redirect_uris') = 'array' " <>
                                "THEN c.metadata->'redirect_uris' ELSE '[]'::jsonb END) AS u " <>
                                "WHERE c.status = 'approved' AND (lower(u) LIKE $1 ESCAPE '\\' " <>
                                "OR lower(u) LIKE $1 || '/%' ESCAPE '\\' OR lower(u) LIKE $1 || ':%' ESCAPE '\\' " <>
                                "OR lower(u) LIKE $1 || '?%' ESCAPE '\\' OR lower(u) LIKE $1 || '#%' ESCAPE '\\') " <>
                                "ORDER BY c.client_id, u LIMIT 50"

  @doc """
  The `https` redirect URIs of `approved` clients whose host starts with `host` (lower case, a candidate list the
  caller still compares exactly): `{:ok, [uri]}`, or `:error` plus ONE value-free WARNING (`OAuth: trusted redirect
  origin lookup failed`, never the host) on any error, timeout or exception. No cache.
  """
  @spec approved_redirect_uris(String.t()) :: {:ok, [String.t()]} | :error
  def approved_redirect_uris(host) when is_binary(host) do
    # exactly `https://<host>` followed by the end or one of `/ : ? #` (never `https://<host>.other/...`)
    pattern = "https://" <> like_escape(host)

    case Ecto.Adapters.SQL.query(repo(), @sql_approved_redirect_uris, [pattern], timeout: 500, pool_timeout: 500) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [uri] -> uri end)}

      {:error, _reason} ->
        Logger.warning("OAuth: trusted redirect origin lookup failed")
        :error
    end
  rescue
    _ ->
      Logger.warning("OAuth: trusted redirect origin lookup failed")
      :error
  catch
    :exit, _ ->
      Logger.warning("OAuth: trusted redirect origin lookup failed")
      :error
  end

  defp like_escape(value), do: String.replace(value, ["\\", "%", "_"], fn char -> "\\" <> char end)

  defp paged(count_sql, page_sql, page, build) do
    with {:ok, %{rows: [[total]]}} <- query(count_sql, []),
         page = clamp_page(page, total),
         {:ok, %{rows: rows}} <- query(page_sql, [@page_size, (page - 1) * @page_size]) do
      {:ok, %{clients: Enum.map(rows, build), total: total, page: page, page_size: @page_size, total_pages: total_pages(total)}}
    else
      {:error, reason} ->
        Logger.error("OAuth.ClientStore: could not list clients: #{error_type(reason)}")
        {:error, reason}

      other ->
        Logger.error("OAuth.ClientStore: unexpected client list result: #{error_type(other)}")
        {:error, :unexpected_result}
    end
  end

  defp total_pages(total), do: max(div(total + @page_size - 1, @page_size), 1)

  defp clamp_page(page, total) when is_integer(page) and page >= 1, do: min(page, total_pages(total))
  defp clamp_page(_page, _total), do: 1

  @doc """
  Deletes PENDING registrations older than `ttl_days` (default: `Nebu.OAuth.Config.pending_limits()`),
  in batches of #{@purge_batch} (at most #{@purge_max_batches} batches per call; the next tick continues).
  `{:ok, deleted}` or `{:error, reason}`.

  Cluster safe without a lock or any node-local state: the DELETE is one atomic statement per
  batch (`FOR UPDATE SKIP LOCKED`), so several nodes running it concurrently split the work and
  never delete a row twice or a row that was decided in the meantime. Only `status = 'pending'`
  rows can ever match (and the database refuses anything else for the runtime role, see
  migration 000040).
  """
  @spec purge_expired_pending(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_expired_pending(opts \\ []) do
    ttl_days = Keyword.get(opts, :ttl_days) || Config.pending_limits().ttl_days
    do_purge(ttl_days, 0, 0)
  end

  defp do_purge(_ttl_days, total, @purge_max_batches), do: {:ok, total}

  defp do_purge(ttl_days, total, batches) do
    case query(@sql_purge_pending, [ttl_days, @purge_batch]) do
      {:ok, %{num_rows: n}} when n >= @purge_batch -> do_purge(ttl_days, total + n, batches + 1)
      {:ok, %{num_rows: n}} -> {:ok, total + n}
      {:error, _} = error -> error
    end
  end

  # ── bulk removal (story oauth-dcr-abuse-hardening, AH8/AH9) ─────────────────

  @bulk_batch 500
  @preview_rows 20
  @max_days 3650

  # The WHERE of preview, count and delete: pending rows inside the snapshot ($1) that match the exact
  # host ($2), the registrable domain ($3: the domain itself or any subdomain, plain string
  # comparison, never LIKE) and the age ($4) — each criterion only when given.
  @bulk_where """
  status = 'pending' AND created_at <= $1
    AND ($2::text IS NULL OR client_host = $2::text)
    AND ($3::text IS NULL OR client_host = $3::text OR right(client_host, length($3::text) + 1) = '.' || $3::text)
    AND ($4::int IS NULL OR created_at < now() - ($4::int * interval '1 day'))
  """

  @sql_bulk_count "SELECT count(*) FROM oauth_clients WHERE " <> @bulk_where

  @sql_bulk_preview """
  SELECT client_id, metadata, application_type, created_at FROM oauth_clients
  WHERE #{@bulk_where}
  ORDER BY created_at DESC, client_id
  LIMIT $5::int
  """

  # One statement: the batch is picked oldest first with `FOR UPDATE SKIP LOCKED` (concurrent callers
  # on any node take disjoint rows, a row being approved right now is skipped) and `status = 'pending'`
  # is re-checked on the outer DELETE (the purge idiom). The batch is a MATERIALIZED CTE: with a plain
  # `IN (SELECT ... LIMIT ... FOR UPDATE SKIP LOCKED)` subquery PostgreSQL may re-scan it and delete more
  # than the LIMIT (seen as 501 rows in a full-suite run on a large table).
  @sql_bulk_delete """
  WITH batch AS MATERIALIZED (
    SELECT client_id FROM oauth_clients
    WHERE #{@bulk_where}
    ORDER BY created_at
    LIMIT $5::int
    FOR UPDATE SKIP LOCKED)
  DELETE FROM oauth_clients
  WHERE status = 'pending' AND client_id IN (SELECT client_id FROM batch)
  RETURNING client_id
  """

  @type criteria :: %{
          optional(:host) => String.t() | nil,
          optional(:match) => :exact | :domain,
          optional(:older_than_days) => integer() | String.t() | nil
        }

  @doc """
  Validates admin criteria (AH9): `%{host:, match: :exact | :domain, older_than_days:}` with at
  least one of host / age. The host is trimmed, must satisfy `Registration.valid_host?/1` on the raw
  input and is lower-cased (blank = absent); `:domain` uses its registrable domain and is refused
  for a public suffix; days are an integer (or a string of digits) in 1..#{@max_days}.

  `{:ok, %{host: exact | nil, domain: domain | nil, days: n | nil}}` (the SQL parameters) or
  `{:error, {:invalid_criteria, reason}}` with reason `:match | :host | :older_than_days |
  :no_criteria | :public_suffix`. No query is made.
  """
  @spec normalize_criteria(term()) :: {:ok, map()} | {:error, {:invalid_criteria, atom()}}
  def normalize_criteria(%{} = criteria) do
    match = Map.get(criteria, :match, :domain)

    with :ok <- check_match(match),
         {:ok, host} <- clean_host(Map.get(criteria, :host)),
         {:ok, days} <- clean_days(Map.get(criteria, :older_than_days)),
         :ok <- at_least_one(host, days),
         {:ok, exact, domain} <- split_host(host, match) do
      {:ok, %{host: exact, domain: domain, days: days}}
    else
      {:error, reason} -> {:error, {:invalid_criteria, reason}}
    end
  end

  def normalize_criteria(_other), do: {:error, {:invalid_criteria, :no_criteria}}

  defp check_match(match) when match in [:exact, :domain], do: :ok
  defp check_match(_), do: {:error, :match}

  defp clean_host(nil), do: {:ok, nil}

  defp clean_host(host) when is_binary(host) do
    case String.trim(host) do
      "" ->
        {:ok, nil}

      # validated on the raw text (no Unicode case folding into ASCII), then lower-cased
      trimmed -> if Registration.valid_host?(trimmed), do: {:ok, String.downcase(trimmed)}, else: {:error, :host}
    end
  end

  defp clean_host(_), do: {:error, :host}

  defp clean_days(nil), do: {:ok, nil}
  defp clean_days(n) when is_integer(n) and n >= 1 and n <= @max_days, do: {:ok, n}
  defp clean_days(n) when is_integer(n), do: {:error, :older_than_days}

  defp clean_days(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} -> clean_days(n)
          _ -> {:error, :older_than_days}
        end
    end
  end

  defp clean_days(_), do: {:error, :older_than_days}

  defp at_least_one(nil, nil), do: {:error, :no_criteria}
  defp at_least_one(_host, _days), do: :ok

  defp split_host(nil, _match), do: {:ok, nil, nil}
  defp split_host(host, :exact), do: {:ok, host, nil}

  defp split_host(host, :domain) do
    case PublicSuffix.classify(host) do
      {:ok, %{public_suffix?: true}} -> {:error, :public_suffix}
      {:ok, %{domain: domain}} -> {:ok, nil, domain}
      {:error, _} -> {:error, :host}
    end
  end

  @doc """
  The database clock (`now()`), the time base of the bulk-removal snapshot: `created_at` is written by the
  database, so a snapshot taken from an application node's clock could miss or sweep rows when the
  clocks differ. `{:ok, DateTime}` (UTC, microseconds) or `{:error, reason}`.
  """
  @spec db_now() :: {:ok, DateTime.t()} | {:error, term()}
  def db_now do
    case query("SELECT now()", []) do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> {:ok, now}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Age of a snapshot `as_of` in microseconds on the DATABASE clock (negative = in the future):
  `{:ok, integer}` or `{:error, reason}`.
  """
  @spec snapshot_age_us(DateTime.t()) :: {:ok, integer()} | {:error, term()}
  def snapshot_age_us(%DateTime{} = as_of) do
    case query("SELECT (extract(epoch FROM (now() - $1::timestamptz)) * 1000000)::bigint", [as_of]) do
      {:ok, %{rows: [[us]]}} when is_integer(us) -> {:ok, us}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Read-only preview of a bulk removal: `{:ok, %{count:, rows:}}` with the number of matching PENDING
  rows (inside the `as_of` snapshot) and the first #{@preview_rows} of them, newest first
  (`%{client_id:, metadata:, application_type:, created_at:}`), `{:error, {:invalid_criteria, _}}`
  without a query, or `{:error, reason}` when the database could not be read.
  """
  @spec bulk_preview(criteria(), DateTime.t()) :: {:ok, %{count: non_neg_integer(), rows: [map()]}} | {:error, term()}
  def bulk_preview(criteria, %DateTime{} = as_of) do
    with {:ok, c} <- normalize_criteria(criteria),
         params = bulk_params(c, as_of),
         {:ok, %{rows: [[count]]}} <- query(@sql_bulk_count, params),
         {:ok, %{rows: rows}} <- query(@sql_bulk_preview, params ++ [@preview_rows]) do
      {:ok,
       %{
         count: count,
         rows:
           Enum.map(rows, fn [id, meta, app, created_at] ->
             %{client_id: id, metadata: decode(meta), application_type: app, created_at: created_at}
           end)
       }}
    end
  end

  @doc """
  Deletes the PENDING registrations matching `criteria` and created at or before `as_of`, at most
  #{@bulk_batch} (oldest first) per call, in ONE transaction. Returns `{:ok, %{removed:, remaining:,
  client_ids:}}` (`remaining` = rows that still match inside the snapshot), `{:error,
  {:invalid_criteria, reason}}` (nothing queried) or `{:error, reason}`.

  Option `:audit` — a 1-arity function receiving the removed client ids, run in the SAME transaction
  after the delete (not when nothing matched): it must return `:ok`; anything else (or a raise, or an
  aborted transaction) rolls the removal back and yields `{:error, {:audit, reason}}`. Approved and
  rejected rows are never touched (SQL `status = 'pending'` and the runtime role's row level security).
  """
  @spec bulk_delete_pending(criteria(), DateTime.t(), keyword()) ::
          {:ok, %{removed: non_neg_integer(), remaining: non_neg_integer(), client_ids: [String.t()]}}
          | {:error, {:invalid_criteria, atom()} | {:audit, term()} | term()}
  def bulk_delete_pending(criteria, %DateTime{} = as_of, opts \\ []) do
    with {:ok, c} <- normalize_criteria(criteria) do
      do_bulk_delete(bulk_params(c, as_of), Keyword.get(opts, :audit, fn _ids -> :ok end))
    end
  end

  defp bulk_params(%{host: host, domain: domain, days: days}, as_of), do: [as_of, host, domain, days]

  defp do_bulk_delete(params, audit) do
    repo = repo()

    result =
      repo.transaction(fn ->
        with {:ok, %{rows: rows}} <- query(@sql_bulk_delete, params ++ [@bulk_batch]),
             ids = List.flatten(rows),
             :ok <- run_audit(audit, ids),
             {:ok, %{rows: [[remaining]]}} <- query(@sql_bulk_count, params) do
          %{removed: length(ids), remaining: remaining, client_ids: ids}
        else
          {:audit, reason} -> repo.rollback({:audit, reason})
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in [RuntimeError, DBConnection.ConnectionError, UndefinedFunctionError] -> {:error, e}
  end

  # Nothing removed => nothing to audit. A raise in the audit function is an audit failure.
  defp run_audit(_audit, []), do: :ok

  defp run_audit(audit, ids) do
    case audit.(ids) do
      :ok -> :ok
      {:error, reason} -> {:audit, reason}
      other -> {:audit, other}
    end
  rescue
    e -> {:audit, e.__struct__}
  end

  @doc """
  Approves a PENDING registration (`approved_by` = admin user id, `approved_at` = now; the
  first-registrant IP / user agent are erased). Returns `:ok`, or `{:error, :not_pending}` when the
  client is unknown or already decided (race guard: a decided registration is never overwritten).

  Option `:audit` — a 0-arity function run INSIDE the same transaction after the row was updated: it
  must return `:ok` or `{:error, reason}`; on `{:error, reason}` the decision is rolled back and
  `{:error, {:audit, reason}}` is returned (a decision is never unaudited).
  """
  @spec approve(String.t(), String.t(), keyword()) :: :ok | {:error, :not_pending | {:audit, term()} | term()}
  def approve(client_id, admin_user_id, opts \\ []), do: decide(@sql_approve, [client_id, admin_user_id], opts)

  @doc "Rejects a PENDING registration (`rejected_by`/`rejected_at`); same contract as `approve/3`. The row is kept."
  @spec reject(String.t(), String.t(), keyword()) :: :ok | {:error, :not_pending | {:audit, term()} | term()}
  def reject(client_id, admin_user_id, opts \\ []), do: decide(@sql_reject, [client_id, admin_user_id], opts)

  defp decide(sql, params, opts) do
    audit = Keyword.get(opts, :audit, fn -> :ok end)
    repo = repo()

    result =
      repo.transaction(fn ->
        case query(sql, params) do
          {:ok, %{num_rows: 1}} ->
            case audit.() do
              :ok -> :ok
              {:error, reason} -> repo.rollback({:audit, reason})
              other -> repo.rollback({:audit, other})
            end

          {:ok, %{num_rows: 0}} ->
            repo.rollback(:not_pending)

          {:error, reason} ->
            repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # repo down / not started (the `:oauth_repo` test seam)
    e in [RuntimeError, DBConnection.ConnectionError, UndefinedFunctionError] -> {:error, e}
  end

  @doc """
  Withdraws an APPROVED client (story oauth-client-revocation, CR1-CR5) in ONE transaction (timeout 120 s):

    1. `UPDATE ... SET status = 'revoked', revoked_by, revoked_at, revoked_reason WHERE status = 'approved'` (0 rows
       => rollback `:not_approved`; this row lock is the FIRST lock of the lock order oauth_clients -> devices ->
       matrix_sessions, and conflicts with the `FOR SHARE` of session issuance and rotation);
    2. `Nebu.Matrix.oauth_end_client_sessions/2`: every session / device of the client in the same transaction;
    3. `oauth_codes.used_at` of the client's unused codes;
    4. DELETE of the client's `oauth_authz_requests` and `oauth_consent_requests`;
    5. the caller's `:audit` function (1-arity, receives the torn-down `{user_id, device_id}` pairs, returns `:ok |
       {:error, reason}`; a raise counts as failed): a failed audit rolls EVERYTHING back.

  After the COMMIT `Nebu.Matrix.oauth_after_device_teardown/1` (JWT denylist, binding deletion), best effort.
  `{:ok, %{devices: n}}`, `{:error, :not_approved}` (unknown / pending / rejected / already revoked),
  `{:error, {:audit, reason}}` or `{:error, reason}` (everything rolled back; the log names only the error TYPE,
  never the reason text).

  Options: `:reason` (binary | nil, normalised by the caller), `:audit`.
  """
  @spec revoke(String.t(), String.t(), keyword()) ::
          {:ok, %{devices: non_neg_integer()}} | {:error, :not_approved | {:audit, term()} | term()}
  def revoke(client_id, actor, opts \\ []) when is_binary(client_id) and is_binary(actor) do
    case do_revoke(client_id, actor, opts) do
      {:error, error} = result ->
        # Lock order oauth_clients -> devices -> matrix_sessions holds for issuance, rotation and this teardown, but
        # `MatrixSessionStore.delete_for_user/1` (account deactivation) and `OAuthSessionStore.delete_by_code_hash/1`
        # delete rows of several devices WITHOUT the devices lock: against them PostgreSQL may pick this transaction as
        # a deadlock victim (SQLSTATE 40P01). Everything was rolled back, so ONE retry is safe (ADR-033, CR4 note).
        if deadlock?(error) do
          Logger.warning("OAuth.ClientStore: client revocation hit a deadlock, retrying once")
          do_revoke(client_id, actor, opts)
        else
          result
        end

      other ->
        other
    end
  end

  defp deadlock?(:deadlock), do: true
  defp deadlock?(%Postgrex.Error{postgres: %{code: :deadlock_detected}}), do: true
  defp deadlock?(_), do: false

  defp do_revoke(client_id, actor, opts) do
    audit = Keyword.get(opts, :audit, fn _pairs -> :ok end)
    reason = Keyword.get(opts, :reason)
    repo = repo()

    result =
      repo.transaction(
        fn ->
          with {:ok, %{num_rows: 1}} <- query(@sql_revoke, [client_id, actor, reason]),
               :ok <- run_revoke_hook(),
               {:ok, pairs} <- Nebu.Matrix.oauth_end_client_sessions(client_id, repo),
               {:ok, _} <- query(@sql_use_codes, [client_id]),
               {:ok, _} <- query(@sql_delete_requests, [client_id]),
               {:ok, _} <- query(@sql_delete_consents, [client_id]),
               :ok <- run_revoke_audit(audit, pairs) do
            pairs
          else
            {:ok, %{num_rows: 0}} -> repo.rollback(:not_approved)
            {:audit, audit_reason} -> repo.rollback({:audit, audit_reason})
            {:error, error} -> repo.rollback(error)
            other -> repo.rollback({:unexpected, other})
          end
        end,
        timeout: 120_000
      )

    case result do
      {:ok, pairs} ->
        _ = Nebu.Matrix.oauth_after_device_teardown(pairs)
        {:ok, %{devices: length(pairs)}}

      {:error, :not_approved} ->
        {:error, :not_approved}

      {:error, error} ->
        Logger.warning("OAuth.ClientStore: client revocation rolled back: #{error_type(error)}")
        {:error, error}
    end
  rescue
    e in [RuntimeError, DBConnection.ConnectionError, UndefinedFunctionError] ->
      Logger.warning("OAuth.ClientStore: client revocation failed: #{error_type(e)}")
      {:error, e}
  end

  # An audit fun that raises (or returns anything but :ok) is a failed audit: the revocation is rolled back.
  defp run_revoke_audit(audit, pairs) do
    case audit.(pairs) do
      :ok -> :ok
      {:error, reason} -> {:audit, reason}
      other -> {:audit, other}
    end
  rescue
    e -> {:audit, e.__struct__}
  end

  # Test seam (compile-guarded, `:nebu_http, :oauth_client_revoke_hook`, 0-arity): runs inside the transaction right
  # after the status UPDATE, before the teardown and the commit (race tests).
  # (a hook that returns `{:error, reason}` makes the transaction roll back with that reason: the deadlock-retry test)
  if Mix.env() == :test do
    defp run_revoke_hook do
      case Application.get_env(:nebu_http, :oauth_client_revoke_hook) do
        fun when is_function(fun, 0) ->
          case fun.() do
            {:error, _} = error -> error
            _ -> :ok
          end

        _ ->
          :ok
      end
    end
  else
    defp run_revoke_hook, do: :ok
  end

  # Type / SQLSTATE only: a driver error carries the failing row, an audit reason may carry text.
  defp error_type(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp error_type({:exception, mod}) when is_atom(mod), do: inspect(mod)
  defp error_type(%{__struct__: struct}), do: inspect(struct)
  defp error_type(reason) when is_atom(reason), do: inspect(reason)
  defp error_type({tag, _detail}) when is_atom(tag), do: inspect(tag)
  defp error_type(_reason), do: "unexpected error"

  # ── helpers ─────────────────────────────────────────────────────────────────

  # 192 random bits, URL-safe, unpadded (32 chars). Server-generated; never client-supplied.
  defp generate_client_id, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  # Test seam (same idiom as `:compliance, :repo`): `:nebu_http, :oauth_repo` replaces the repo so
  # tests can simulate an unavailable database. Production always uses `Nebu.Repo`.
  defp repo, do: Application.get_env(:nebu_http, :oauth_repo, Nebu.Repo)

  defp query(sql, params) do
    Ecto.Adapters.SQL.query(repo(), sql, params)
  rescue
    e in [RuntimeError, DBConnection.ConnectionError, DBConnection.EncodeError] -> {:error, e}
  end

  # jsonb comes back decoded (map); a row whose JSON text was stored as a jsonb STRING (manual
  # inserts) is decoded once more so callers always see a map.
  defp decode(%{} = map), do: map

  defp decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  # Lower-cased host of metadata["client_uri"] (nil when absent/unparsable).
  defp host_of(%{"client_uri" => uri}) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp host_of(_), do: nil

  defp domain_of(host) when is_binary(host) do
    case PublicSuffix.registrable_domain(host) do
      {:ok, domain} -> domain
      _ -> nil
    end
  end

  defp domain_of(_), do: nil

  defp truncate(nil, _max), do: nil

  defp truncate(value, max) when is_binary(value) do
    # The user agent is client supplied: keep it valid UTF-8 and bounded (jsonb/text columns reject
    # invalid sequences).
    if String.valid?(value), do: String.slice(value, 0, max), else: nil
  end
end
