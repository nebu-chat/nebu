defmodule Nebu.Media.StorageConfig do
  @moduledoc """
  ETS-backed cache for the singleton `media_storage_config` table (story
  `media-security-admin-control/11a-storage-config-schema-secrets`).

  ## Purpose

  The S3/MinIO storage target comes from the boot-time `NEBU_MINIO_*`/
  `NEBU_S3_REGION` env vars (`server/config/runtime.exs`) unless an admin saved
  an override for it. This module holds that admin-configurable override, with
  `access_key`/`secret_key` encrypted at rest via `Nebu.Web.SecretBox` (never a
  second, parallel AES helper — see the story's Dev Agent Guardrails).
  `Nebu.Media.Storage` resolves the effective target from here on every call
  (`request_target/0`), so a saved change needs no restart.

  This is a **separate** cache instance from `Nebu.Media.Config` (Story 9a) —
  its own ETS table (`:nebu_media_storage_config`), its own `:pg` group
  (`"nebu_media_storage_config"`), never shared, per the story's Summary:
  storage-target changes are rare/security-sensitive and must never couple to
  `media_config`'s hot-path invalidation group.

  ## Interface

  - `get/0` — the merged config map (DB row > env-var fallback > compiled
    default, per field), with `access_key`/`secret_key` **masked** (AC8).
    Never returns a decrypted secret. The keys shown are the pair the
    operational path would sign with (none for a half pair, undecryptable
    keys, or another endpoint than the environment's without saved keys).
  - `get_for_connection/0` — same merge, but `access_key`/`secret_key` are
    the plaintext pair. No production caller (the operational path uses
    `request_target/0`); kept for tests and diagnostics. Not exposed to any
    LiveView/JSON-facing surface.
  - `request_target/0` — the per-request `ExAws` overrides and the effective
    bucket / archive bucket for one operational S3 call of
    `Nebu.Media.Storage`: an error atom (no request) for a blank or invalid
    endpoint, missing / unreadable credentials or unreadable saved settings,
    never a fallback to the boot-time config.
    `archive_bucket/0` is the effective archive bucket alone;
    `key_prefix_template/0` the effective object key prefix template (both
    read no secret).
  - `stored_target?/2` — whether an endpoint and Use SSL are the stored
    (effective) target; the settings form words the Test Connection answer
    with it.
  - `describe_invalid_endpoint/1` — the admin-facing reason why an endpoint
    was refused (`{:error, :invalid_endpoint}` carries no detail).
  - `upsert/2` — `upsert(%{field => value, ...}, actor)`, a partial-update map.
    The ONLY write path to `media_storage_config`. Rejects an `endpoint` in
    `fields` the same way `test_connection/1` does (see below) BEFORE any DB
    write — fixed post-epic per Kassandra's epic-end security review finding
    M-3 (2026-07-20): previously `endpoint` was stored verbatim with no
    validation at all on this path. Also `{:error, :secret_required}` (a
    changed `endpoint` / `use_ssl` without both keys), `{:error,
    :key_pair_required}` (exactly one key mentioned) and `{:error,
    :storage_config_unavailable}` (the row being written cannot be read).
  - `persisted_target/0` — (story `11b-storage-ui-test-connection`) returns
    `{:ok, %{endpoint: ..., bucket: ...}}` when a `media_storage_config` row
    has ever been written, or `:fresh` when none has. This is the AC4
    orphan-risk-gate baseline for `Nebu.Admin.MediaSettingsController` —
    deliberately NOT `get/0`'s env-var/compiled-default-merged view, since a
    config that was never explicitly saved must never gate on the
    orphan-risk warning regardless of what the compiled/env-var default
    endpoint/bucket happens to be. Reads the same raw-row ingredient as
    `get/0`/`get_for_connection/0` (the `:media_storage_config_loader` seam,
    or a real `SELECT` when unset) — never touches `media_files`.
  - `test_connection/1` — (story `11b-storage-ui-test-connection`) accepts a
    candidate map (`%{endpoint:, bucket:, region:, use_ssl:, access_key:,
    secret_key:}`), resolves any blank secret against the currently stored
    decrypted secret internally (never returning it to the caller), and
    issues a single S3 `HEAD` against the candidate bucket root via the
    `:media_storage_test_connection_fun` test seam (falling back to a real
    `ExAws` call). Returns `:ok` or `{:error, reason}` — never persists.
    Rejects a candidate `endpoint` carrying an `http://`/`https://` scheme
    prefix (`{:error, :invalid_endpoint}`) BEFORE issuing any real request —
    this module's own env-var-fallback env reader and `runtime.exs`'s
    `NEBU_MINIO_ENDPOINT` both use a bare `host[:port]` contract (no scheme),
    so a scheme-prefixed candidate is always a malformed/attacker-influenced
    value, not a legitimate configuration this module would ever itself
    produce. Beyond the scheme check, also resolves the host and rejects a
    private/loopback/link-local/CGNAT/cloud-metadata address via the SAME
    shared `Nebu.Media.SSRF.checked_target/1` guard `preview_url` and both
    webhook paths already use — fixed post-epic per Kassandra's epic-end
    security review finding M-2 (2026-07-20); previously only the scheme
    prefix was checked (forward-carried, under-scoped, from the 11a security
    review), leaving a blind admin-authenticated SSRF against internal
    infrastructure/cloud metadata endpoints.

    **Pinned target** (story `storage-test-pinned-target`, follow-up `do` part
    a): the target the SSRF check returned (`%{scheme, host, ip}`, the host
    resolved ONCE, every answer checked) is handed on to the request under
    `:pinned_target` in the candidate map, and the real `ExAws` request is made
    by `Nebu.Media.PinnedHttpClient`, which connects to that checked IP and
    keeps the ORIGINAL host name for the `Host` header (the SigV4 signature),
    the TLS SNI and the certificate hostname verification. There is no second
    DNS resolution between the check and the request (no DNS-rebinding window).
    `upsert/1` (save) performs no request, so there is nothing to pin there; the
    operational S3 calls of `Nebu.Media.Storage` (`request_target/0`) use the
    configured HTTP client and resolve the stored host per request, not pinned
    (a residual of the admin-trusted endpoint, see ADR-033 SO11 addendum).
    The same client also maps hackney 4.x's `HEAD` answer (a 3-tuple)
    that `ExAws.Request.Hackney` did not understand: the production test
    connection used to raise a `CaseClauseError` against any server.

  ## ETS table

  A named `:protected` set `:nebu_media_storage_config` with
  `read_concurrency: true`, owned by this GenServer — mirrors
  `Nebu.Media.Config` structurally but is its own dedicated instance. Unlike
  `Nebu.Media.Config`, the cached value NEVER holds a decrypted secret: only
  the raw DB row (its `access_key_encrypted`/`secret_key_encrypted` columns
  still `Nebu.Web.SecretBox` ciphertext, or `nil` if unset) and the raw
  env-var map are cached. `access_key`/`secret_key` are decrypted via
  `Nebu.Web.SecretBox.decrypt/1` freshly on every `get/0`/`get_for_connection/0`
  call (see `resolved/0`) — this ETS table is `:protected`, i.e.
  VM-globally readable by any process via `:ets.lookup/2`, so no plaintext
  secret byte may ever sit in it at rest.

  ## Cluster propagation + TTL fallback (AC7)

  The GenServer joins the `nebu_media_storage_config` `:pg` group on init.
  Every successful `upsert/1` re-reads the DB, updates the local ETS cache,
  and broadcasts `{:invalidate_media_storage_config}` to every OTHER `:pg`
  group member. A `Process.send_after(self(), :ttl_tick, 60_000)`
  self-message loop forces a re-read every 60 seconds regardless of broadcast
  receipt, so a node that misses an invalidation (network partition) cannot
  serve a stale endpoint/credential indefinitely.

  ## Supervision

  Started unconditionally by `Nebu.Application` (via the dedicated
  `Nebu.Media.StorageConfig.Supervisor`, not gated behind any `:start_xxx`
  test flag) — mirrors `Nebu.Media.Config.Supervisor`'s placement exactly.
  AC7 requires changes to take effect cluster-wide without a restart, which
  requires this to be a genuinely supervised, always-running process: a
  crash must repopulate the ETS cache automatically.

  ## Read/write seams (ADR-018 / test isolation)

  - `Application.get_env(:nebu_http, :media_storage_config_source)` —
    0-arity fun. When set, `get/0` calls it directly (bypassing ETS/
    GenServer/DB/env-fallback entirely) and merges the returned map over the
    compiled defaults. Test-only fast path, mirrors `:media_config_source`.
  - `Application.get_env(:nebu_http, :media_storage_config_loader)` —
    0-arity fun returning the current persisted `media_storage_config` row as
    a STRING-keyed map (column names), or `nil` when no row has ever been
    written (a confirmed absence, which replaces the cached snapshot), or
    `{:error, term}` (or a raise) when the row could not be read: a failed
    read keeps the last good snapshot (a refresh) or, with none, makes
    `request_target/0` fail instead of using the environment target.
    Consulted by the GenServer's DB-refresh step AND directly by
    `get/0`/`get_for_connection/0` whenever the ETS table is not yet
    populated. Defaults to a real `SELECT ... FROM media_storage_config` when
    unset (a failed query or an unavailable Repo is an `{:error, _}`).
  - `Application.get_env(:nebu_http, :media_storage_config_writer)` — arity-2
    fun `fn columns, set_at -> :ok | {:error, term()} end`, where `columns`
    is a STRING-keyed map containing ONLY the columns that changed for this
    `upsert/1` call (already `SecretBox`-encrypted for
    `access_key_encrypted`/`secret_key_encrypted` when those fields were
    present). Defaults to a real `INSERT ... ON CONFLICT (id) DO UPDATE`
    with a partial `SET` clause when unset.
  - `Application.get_env(:nebu_http, :media_storage_env_reader)` — 0-arity
    fun returning a STRING-keyed map standing in for the `NEBU_MINIO_*`/
    `NEBU_S3_REGION` env vars `server/config/runtime.exs` already reads at
    boot. Any absent/nil key means "not set", exactly like
    `System.get_env/1`'s own contract. Defaults to a real `System.get_env/1`
    read of each var when unset.

  Read/write is inline SQL per ADR-018 (no repository/service layer) — this
  module is the coherent single owner of the `media_storage_config`
  capability.

  ## Secret encryption — reuse, do not reinvent

  `access_key`/`secret_key` are encrypted via `Nebu.Web.SecretBox.encrypt/1`
  before ever touching the DB, and decrypted via
  `Nebu.Web.SecretBox.decrypt/1` for `get_for_connection/0`. No second,
  parallel AES-256-GCM call site — `Nebu.Media.Crypto.encrypt/3`/`decrypt/3`
  is never called directly from this module. `SecretBox.encrypt/1` raises
  (fails closed) when no at-rest secret is configured; `upsert/1` lets that
  raise propagate rather than swallowing it into a stored-plaintext fallback.
  """

  use GenServer
  require Logger

  alias Nebu.Compliance.AuditWriter
  alias Nebu.Media.SSRF
  alias Nebu.Web.SecretBox

  @table :nebu_media_storage_config
  @pg_group "nebu_media_storage_config"
  @ttl_ms 60_000
  @audit_actor "system:media_storage_config"
  @audit_action "media_storage_config_updated"
  @audit_target_type "media_storage_config"
  @audit_target_id "1"

  # Story 11c: exact supported placeholder set for s3_key_prefix_template.
  # {media_id} is mandatory (AC2/AC6 — see validate_template/1); the other 4
  # are optional. No other placeholder (e.g. {room_id}) is ever recognized —
  # media_files has no room_id column (ADR-028/ADR-029) — do not add one here
  # without a new story explicitly updating this list and its validation.
  @placeholders ~w({media_id} {year} {month} {day} {server_name})

  # config.exs-matching defaults (AC4's table) — the unmasked, plaintext
  # shape both get/0 (before masking) and get_for_connection/0 return.
  @defaults %{
    endpoint: "minio:9000",
    bucket: "nebu-media",
    region: "us-east-1",
    use_ssl: false,
    access_key: nil,
    secret_key: nil,
    s3_key_prefix_template: "{media_id}",
    archive_bucket: nil,
    # bugfix-upcloud-s3-iam-sts-endpoints (AC1) / bugfix-add-sts-iam-endpoints-
    # to-admin-ui (AC1): env-resolved full URLs (UpCloud IAM/STS endpoints).
    # Since the latter story, admin-settable via a media_storage_config
    # DB-override column (same DB > env > default precedence as every other
    # plain field) — still never masked (not secrets). See build_resolved/2
    # and default_env_reader/0 below. A non-nil write to either column is
    # validated by validate_iam_sts_fields/1 in upsert/1's `with` chain (F-1
    # fix, Kassandra security review, SEC Gate 1, 2026-10-08) — nil (unset)
    # and env/default-sourced values are never re-validated by this check.
    iam_endpoint: nil,
    sts_endpoint: nil
  }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Returns the merged config map (AC4/AC5), `access_key`/`secret_key`
  **masked** (AC8). Never returns a decrypted secret.
  """
  @spec get() :: map()
  def get do
    case Application.get_env(:nebu_http, :media_storage_config_source) do
      fun when is_function(fun, 0) -> fun.() |> merge_over_defaults() |> mask_map()
      _ -> resolved() |> mask_map()
    end
  end

  @doc """
  Returns the merged config map (AC4/AC5), `access_key`/`secret_key`
  **decrypted to plaintext** (`nil` where `get/0` shows none). The only
  function that hands out the plaintext keys in a config map. It is NOT what
  the operational S3 calls use (`request_target/0` is; it also reports why a
  pair is unusable) and has no production caller. Never call this from a
  LiveView assign, a JSON response, or any other admin-facing surface.
  """
  @spec get_for_connection() :: map()
  def get_for_connection do
    resolved()
  end

  @doc """
  What `Nebu.Media.Storage` needs to address the object store for ONE operation, resolved now (DB > env >
  default, see `get_for_connection/0`): the per-request `ExAws` config overrides (host, scheme, port, region,
  credentials) plus the effective primary and archive bucket names.

  Never written into the global `:ex_aws` app env: the overrides travel with the request, so a changed saved
  target is in effect on the next call, on every node, and concurrent calls cannot see each other's values.
  Unlike the Test Connection overrides, these keep the configured `ExAws` HTTP client and retry policy.

  The credentials are bound to the target they were meant for: an endpoint saved in the admin settings is only ever
  used with the credentials saved with it. A saved credential that is missing or cannot be decrypted is an error,
  not replaced by the `NEBU_MINIO_*` credentials (they would sign requests to a host they were not meant for).
  The one exception is the environment's own target: a saved endpoint and Use SSL that equal the environment's,
  with both saved keys empty, use the `NEBU_MINIO_*` credentials. Without a saved endpoint, saved credentials win
  over the environment's and follow the environment's endpoint; that row shape only exists for legacy / SQL-written
  rows: the Admin form saves the keys together with `endpoint` and `use_ssl`, so after a UI save the target is pinned
  and a later change of `NEBU_MINIO_ENDPOINT` is not followed. A half-saved or undecryptable pair is an error in
  every case.

  Errors, all without any credential or path in them (the caller must not send a request, and must not fall back
  to the boot-time config): `:storage_endpoint_blank` (no host: empty, whitespace only or just `:port`),
  `:storage_endpoint_invalid` (anything else that is not `host[:port]`), `:storage_credentials_missing`,
  `:storage_credentials_unreadable` (a secret file or the at-rest key cannot be read) and
  `:storage_config_unavailable` (the saved settings cannot be read and no earlier snapshot exists). Never raises.
  """
  @spec request_target() ::
          {:ok, %{overrides: keyword(), bucket: String.t(), archive_bucket: String.t()}}
          | {:error,
             :storage_endpoint_blank
             | :storage_endpoint_invalid
             | :storage_credentials_missing
             | :storage_credentials_unreadable
             | :storage_config_unavailable}
  def request_target do
    with {:ok, {row, env}} <- read_snapshot(),
         cfg = plain_fields(row, env),
         {:ok, host, port} <- parse_endpoint(cfg.endpoint, cfg.use_ssl),
         {:ok, access_key, secret_key} <- operation_credentials(row, env) do
      cfg = Map.merge(cfg, %{access_key: access_key, secret_key: secret_key})
      {:ok, %{overrides: connection_overrides(host, port, cfg), bucket: cfg.bucket, archive_bucket: archive_bucket(cfg)}}
    end
  end

  @doc """
  Whether `endpoint` and `use_ssl` are the stored (effective) target, compared the way Test Connection does: trimmed,
  ASCII-downcased endpoint, `use_ssl == true`. The settings form uses it to word the Test Connection answer when the
  stored keys of THAT target are unusable.
  """
  @spec stored_target?(String.t() | nil, boolean() | nil) :: boolean()
  def stored_target?(endpoint, use_ssl) do
    {row, env} = row_and_env()
    same_target?(%{endpoint: endpoint, use_ssl: use_ssl}, plain_fields(row, env))
  end

  @doc """
  The effective archive bucket name: the saved one, else `:nebu_http, :media_archive_bucket`
  (`NEBU_MINIO_ARCHIVE_BUCKET`, set by `runtime.exs`), else `"nebu-media-archive"`. Needs no usable endpoint and
  never touches a credential or a secret file.
  """
  @spec archive_bucket() :: String.t()
  def archive_bucket do
    {row, env} = row_and_env()
    archive_bucket(plain_fields(row, env))
  end

  @doc """
  The effective object key prefix template (`s3_key_prefix_template`, see `compute_key/2`). Reads no secret (no
  decryption, no secret file), so a missing key file cannot break an upload before it reaches storage; honours the
  `:media_storage_config_source` seam like `get/0`.
  """
  @spec key_prefix_template() :: String.t()
  def key_prefix_template do
    case Application.get_env(:nebu_http, :media_storage_config_source) do
      fun when is_function(fun, 0) ->
        fun.() |> merge_over_defaults() |> Map.fetch!(:s3_key_prefix_template)

      _ ->
        {row, env} = row_and_env()
        plain_fields(row, env).s3_key_prefix_template
    end
  end

  defp archive_bucket(%{archive_bucket: bucket}) when is_binary(bucket) and bucket != "", do: bucket
  defp archive_bucket(_cfg), do: Application.get_env(:nebu_http, :media_archive_bucket, "nebu-media-archive")

  # The credentials of ONE operational request, from the source the endpoint comes from (see `request_target/0`).
  # A signed request is only ever sent with credentials that were meant for its host. When the environment's
  # credentials apply but none is configured, the request is signed with empty strings (what `runtime.exs` boots
  # with), never with `nil`, which ExAws cannot sign with.
  defp operation_credentials(row, env) do
    env_credentials? = env_credentials_apply?(row, env)

    case {saved_secret(row, "access_key_encrypted"), saved_secret(row, "secret_key_encrypted")} do
      {{:ok, access_key}, {:ok, secret_key}} -> {:ok, access_key, secret_key}
      {:none, :none} when env_credentials? -> env_credentials(env)
      {:unreadable, _} -> {:error, :storage_credentials_unreadable}
      {_, :unreadable} -> {:error, :storage_credentials_unreadable}
      _ -> {:error, :storage_credentials_missing}
    end
  end

  # The `NEBU_MINIO_*` credentials are meant for the environment's own target: they apply when the row has no endpoint,
  # or when its endpoint and Use SSL are exactly the environment's (a first save that kept the form's pre-filled values,
  # or a legacy row without keys). Any other target never gets them, and a later change of the environment's endpoint
  # ends the match again.
  defp env_credentials_apply?(row, env) do
    row_get(row, "endpoint") == nil or same_target?(plain_fields(row, env), plain_fields(nil, env))
  end

  # `{:ok, plaintext}`, `:none` (column NULL), `:undecryptable` (corrupt or encrypted under another at-rest key) or
  # `:unreadable` (`SecretBox` cannot get its at-rest key, e.g. the key file is missing). Logs nothing: the caller
  # reports once per operation.
  defp saved_secret(row, column) do
    case row_get(row, column) do
      nil ->
        :none

      ciphertext ->
        case SecretBox.decrypt(ciphertext) do
          {:ok, plaintext} -> {:ok, plaintext}
          {:error, _reason} -> :undecryptable
        end
    end
  rescue
    _ -> :unreadable
  end

  defp env_credentials(env) do
    {:ok, resolve_env_secret(env, "NEBU_MINIO_ACCESS_KEY_FILE", "NEBU_MINIO_ACCESS_KEY") || "",
     resolve_env_secret(env, "NEBU_MINIO_SECRET_KEY_FILE", "NEBU_MINIO_SECRET_KEY") || ""}
  rescue
    _ -> {:error, :storage_credentials_unreadable}
  end

  @doc """
  The ONLY write path to `media_storage_config` (AC6). `fields` is a
  partial-update map — only the keys present are written; omitted fields are
  left untouched (AC5/AT6). Encrypts `access_key`/`secret_key` via
  `Nebu.Web.SecretBox.encrypt/1` before touching the DB (AC3); a save that
  changes `endpoint` or `use_ssl` versus the effective value must carry BOTH
  `access_key` and `secret_key` (`{:error, :secret_required}` otherwise, nothing
  written or audited: the stored keys sign the operational requests to the stored
  target only, see `request_target/0`; the row being written is read fresh for
  this, `{:error, :storage_config_unavailable}` when it cannot be read);
  exactly one key in `fields` (a lone `access_key` or `secret_key`, also `nil`)
  is `{:error, :key_pair_required}` (both `nil` clears the pair); an `endpoint`
  the operational parser rejects is `{:error, :invalid_endpoint}`; a fail-closed
  raise from `SecretBox.encrypt/1` propagates BEFORE any DB write (AT12). On
  success, writes a `media_storage_config_updated` audit-log entry with
  `changed_fields` naming ONLY the fields whose submitted value differs from the
  row as it was before the write (every submitted field when there was no row;
  submitted keys always count) — never their values (AC9) — then unconditionally refreshes this node's cache (and broadcasts
  the invalidation to `:pg` peers) before returning `:ok`.

  Also rejects a non-`nil` `iam_endpoint`/`sts_endpoint` in `fields` that is
  not a full `https://` URL passing `Nebu.Media.SSRF.checked_target/1` (F-1
  fix, Kassandra security review, SEC Gate 1, 2026-10-08) — see
  `validate_iam_sts_fields/1` below. `nil` (the explicit "clear this
  override" value) is always accepted unvalidated.
  """
  @spec upsert(map(), String.t()) :: :ok | {:error, term()}
  def upsert(fields, actor \\ @audit_actor) when is_map(fields) do
    fields = without_blank_keys(fields)

    with :ok <- validate_template_field(fields),
         :ok <- validate_endpoint_field(fields),
         :ok <- validate_keys_for_target_change(fields),
         :ok <- validate_key_pair(fields),
         :ok <- validate_iam_sts_fields(fields) do
      columns = build_columns(fields)
      writer = Application.get_env(:nebu_http, :media_storage_config_writer, &default_writer/2)
      set_at = System.system_time(:millisecond)
      # the audit names what differs from the row as it was before this write
      row_before = load_row()

      case writer.(columns, set_at) do
        :ok ->
          write_audit(actor, changed_fields(fields, row_before))
          refresh_cache()
          :ok

        {:error, _reason} = err ->
          err
      end
    end
  end

  # Story 11c AC5: validate s3_key_prefix_template BEFORE any DB write,
  # whenever `fields` contains that key. Absent key => nothing to validate,
  # every other field is untouched by this check (partial-update semantics).
  defp validate_template_field(%{s3_key_prefix_template: template}), do: validate_template(template)
  defp validate_template_field(_fields), do: :ok

  # M-3 fix (epic security review, 2026-07-20): validate `endpoint` BEFORE any
  # DB write, whenever `fields` contains that key — same partial-update-aware
  # gating as `validate_template_field/1` above. Prior to this fix, `upsert/1`
  # stored `endpoint` verbatim with NO validation at all (the scheme-only
  # guard ran only inside `test_connection/1`), so a private-host or
  # scheme-prefixed endpoint could be persisted directly — skipping
  # test-connection entirely — and later used by `Nebu.Media.Storage` for
  # real object-store traffic. Reuses `validate_candidate_endpoint/1` (the
  # SAME function `test_connection/1` calls, see its own doc below) so both
  # the test-connection and the persist path enforce an identical contract.
  #
  # The save path performs no request (storage-test-pinned-target D4), so the checked target returned by
  # `validate_candidate_endpoint/1` is not kept here: there is no second resolution to pin.
  defp validate_endpoint_field(%{endpoint: endpoint}) do
    with {:ok, _target} <- validate_candidate_endpoint(endpoint), do: :ok
  end

  defp validate_endpoint_field(_fields), do: :ok

  # The stored credentials sign the operational requests to the stored target only (`request_target/0`), so a save that
  # moves `endpoint` or `use_ssl` away from the effective value must bring BOTH keys: the same rule (`same_target?/2`) and
  # error as Test Connection. Otherwise the old keys would be sent to a host they were never meant for.
  #
  # The comparison base is a fresh, strict read of the row that is about to be written, never the cached snapshot (a
  # stale cache must neither let a changed endpoint keep the old keys nor reject an unchanged one). A row that cannot be
  # read fails the save: it cannot be decided whether the old keys would stay with another target.
  defp validate_keys_for_target_change(fields) do
    if (Map.has_key?(fields, :endpoint) or Map.has_key?(fields, :use_ssl)) and not keys_given?(fields) do
      with {:ok, row} <- load_row() do
        effective = plain_fields(row, safe_env())
        candidate = %{endpoint: Map.get(fields, :endpoint, effective.endpoint), use_ssl: Map.get(fields, :use_ssl, effective.use_ssl)}

        if same_target?(candidate, effective), do: :ok, else: {:error, :secret_required}
      end
    else
      :ok
    end
  end

  # Exactly one key is never written: the operational path needs the pair (`operation_credentials/2`), so a lone key
  # (a non-blank one, or a `nil` / blank one that would clear half of a pair) would leave the saved target without
  # usable credentials. Both keys `nil` (clear the pair) or neither key mentioned is fine. Evaluated after the
  # changed-target rule above.
  defp validate_key_pair(fields) do
    mentioned = Enum.count([:access_key, :secret_key], &Map.has_key?(fields, &1))
    present = Enum.count([:access_key, :secret_key], &present_key?(Map.get(fields, &1)))

    if mentioned == 1 or present == 1, do: {:error, :key_pair_required}, else: :ok
  end

  defp keys_given?(fields), do: Enum.all?([:access_key, :secret_key], &present_key?(Map.get(fields, &1)))

  defp present_key?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_key?(_value), do: false

  # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08): validates
  # iam_endpoint/sts_endpoint BEFORE any DB write, whenever `fields` contains
  # either key — same partial-update-aware gating as validate_template_field/1
  # and validate_endpoint_field/1 above. Guards the persist path regardless of
  # caller (not just Nebu.Admin.MediaSettingsController's own controller-level
  # mirror of this check, `validate_changes_iam_sts/1`), closing the gap the
  # security review flagged: these two columns were the only admin-writable,
  # DB-persisted, URL-shaped fields on this table with no scheme assertion and
  # no SSRF guard — unlike `endpoint` (validate_endpoint_field/1 above) and
  # `webhook_url` (Nebu.Media.WebhookDelivery), both of which already route
  # through Nebu.Media.SSRF.checked_target/1 at persist/send time. Prior to
  # this fix, the only thing that made this acceptable at LOW was "no DB write
  # path exists at all" — a guarantee the bugfix-add-sts-iam-endpoints-to-
  # admin-ui story itself removed by adding column_for/2 clauses for both
  # keys.
  #
  # A `nil` value is ALWAYS accepted unvalidated — see
  # Nebu.Admin.MediaSettingsController.put_env_backed_field/5's rule 2: `nil`
  # is the explicit "clear this override, go back to env-controlled" value,
  # not a candidate endpoint to validate. A key absent from `fields` entirely
  # is likewise untouched (partial-update semantics, same as
  # validate_endpoint_field/1). Only a non-nil value gets the `https://` +
  # `SSRF.checked_target/1` check — unlike validate_candidate_endpoint/1 above
  # (endpoint's own guard), no synthetic scheme prefix needs to be prepended
  # here: iam_endpoint/sts_endpoint are already full URLs (UpCloud's own
  # iam_url/sts_url shape), so `SSRF.checked_target/1` is called directly.
  defp validate_iam_sts_fields(fields) do
    with :ok <- validate_iam_sts_field(:iam_endpoint, fields),
         :ok <- validate_iam_sts_field(:sts_endpoint, fields) do
      :ok
    end
  end

  defp validate_iam_sts_field(key, fields) do
    case Map.fetch(fields, key) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, value} when is_binary(value) -> validate_iam_sts_url(value)
      {:ok, _other} -> {:error, :invalid_iam_sts_endpoint}
    end
  end

  defp validate_iam_sts_url(value) do
    cond do
      not String.starts_with?(String.downcase(value), "https://") ->
        {:error, :invalid_iam_sts_endpoint}

      # before the SSRF check and before any log line: nothing of such a URL (a password may hold `/`, `?` or `#`, so even `URI.parse(value).host`
      # can be a piece of the credential) is logged or echoed
      iam_sts_user_info?(value) ->
        Logger.warning("Nebu.Media.StorageConfig: IAM/STS endpoint rejected: the URL carries user info (the URL is not logged)")
        {:error, :invalid_iam_sts_endpoint}

      true ->
        case SSRF.checked_target(value, allow_private: SSRF.allow_private_storage?()) do
          {:ok, _target} ->
            :ok

          {:error, reason} ->
            Logger.warning("Nebu.Media.StorageConfig: IAM/STS endpoint host #{inspect(URI.parse(value).host)} rejected: " <> SSRF.describe_error(reason))

            {:error, :invalid_iam_sts_endpoint}
        end
    end
  end

  @doc """
  Whether an IAM / STS endpoint URL carries user info (`https://user:password@host`). Any `@` counts: a password with `/`, `?` or `#` moves the `@` out of what
  `URI.parse/1` reads as the authority, so the parsed `userinfo` alone is not enough. A host URL has no legitimate `@`. Used by this module and by the
  admin form's own mirror of the check (`Nebu.Admin.MediaSettingsController`), so that both layers agree.
  """
  @spec iam_sts_user_info?(String.t()) :: boolean()
  def iam_sts_user_info?(url) when is_binary(url), do: String.contains?(url, "@") or URI.parse(url).userinfo != nil

  @doc "The `:pg` group used for cross-node cache invalidation (ADR-020)."
  @spec pg_group() :: String.t()
  def pg_group, do: @pg_group

  @doc """
  AC4 orphan-risk-gate baseline (story `11b-storage-ui-test-connection`).
  Returns `{:ok, %{endpoint: ..., bucket: ...}}` when a `media_storage_config`
  row has ever been written, or `:fresh` when none has. See moduledoc.
  """
  @spec persisted_target() :: {:ok, %{endpoint: String.t() | nil, bucket: String.t() | nil}} | :fresh
  def persisted_target do
    case safe_load() do
      nil -> :fresh
      row -> {:ok, %{endpoint: Map.get(row, "endpoint"), bucket: Map.get(row, "bucket")}}
    end
  end

  @doc """
  N2-MINOR-1 fix (`bugfix-add-sts-iam-endpoints-to-admin-ui`, finding raised
  in code-review cycle 2, fixed in dev-story cycle 3): returns the RAW,
  DB-ONLY `iam_endpoint`/`sts_endpoint` values —
  `nil` for a field whenever no `media_storage_config` row has ever been
  written, OR a row exists but that specific column was never overridden.
  Deliberately NOT `get/0`'s/`build_resolved/2`'s DB>env>default MERGED
  view — this is the same distinction `persisted_target/0` above already
  draws for `endpoint`/`bucket` (the AC4 orphan-risk-gate baseline),
  extended to these two columns.

  This is the baseline `Nebu.Admin.MediaSettingsController.put_env_backed_field/5`
  needs to tell "a DB override genuinely exists for this field" apart from
  "the resolved value merely happens to be non-blank because an env var is
  set" — without it, blanking an env-sourced (no DB override) field cannot
  be distinguished from blanking a genuine DB override, so the former was
  incorrectly written as a redundant `SET ... = NULL` (there being nothing
  to actually clear) plus a false audit `changed_fields` entry, forever
  non-convergent. Reads the same raw-row ingredient as `persisted_target/0`/
  `get/0` (the `:media_storage_config_loader` seam, or a real `SELECT` when
  unset) — never touches `media_files`.
  """
  @spec persisted_iam_sts() :: %{iam_endpoint: String.t() | nil, sts_endpoint: String.t() | nil}
  def persisted_iam_sts do
    case safe_load() do
      nil -> %{iam_endpoint: nil, sts_endpoint: nil}
      row -> %{iam_endpoint: Map.get(row, "iam_endpoint"), sts_endpoint: Map.get(row, "sts_endpoint")}
    end
  end

  @doc """
  Tests connectivity against the SUBMITTED, not-yet-saved candidate
  configuration (story `11b-storage-ui-test-connection`, AC3). Never
  persists, never reaches the write path. See moduledoc for the seam and the
  SSRF/transport-downgrade endpoint guard.
  """
  @spec test_connection(map()) :: :ok | {:error, term()}
  def test_connection(candidate) when is_map(candidate) do
    with {:ok, target} <- validate_candidate_endpoint(Map.get(candidate, :endpoint)),
         {:ok, resolved} <- resolve_candidate_secrets(candidate) do
      fun = Application.get_env(:nebu_http, :media_storage_test_connection_fun, &default_test_connection/1)
      # D1 (storage-test-pinned-target): the checked target travels with the candidate to the request.
      # The target's scheme is the SSRF check's synthetic `http` (the contract is a bare `host[:port]`): carry the real transport.
      scheme = if Map.get(resolved, :use_ssl) == true, do: "https", else: "http"
      fun.(Map.put(resolved, :pinned_target, %{target | scheme: scheme}))
    end
  end

  @doc """
  Story `11c-s3-key-prefix-template` AC5: validates a candidate
  `s3_key_prefix_template` string BEFORE it is ever persisted. Called from
  `upsert/1` whenever `fields` contains `:s3_key_prefix_template` — this is
  the ONLY place this validation runs; `compute_key/2` deliberately does NOT
  re-validate (see its own @doc and the story's Dev Agent Guardrails).

  Rejects (all as `{:error, :invalid_key_prefix_template}`):

    * unbalanced/unparseable brace syntax (a `{` or `}` not part of a
      complete, non-nested `{...}` span);
    * any `{...}` token that is not exactly one of the 5 recognized
      placeholders (`@placeholders`) — e.g. `{room_id}`, `{yeat}` (typo);
    * a template missing the mandatory `{media_id}` placeholder (AC2/AC6 —
      this is what makes generated keys collision-resistant by construction);
    * a template that would produce a path-escaping key: a literal `".."`,
      a leading `"/"`, or a literal `"//"` in the literal (non-placeholder)
      skeleton of the template.

  Accepts `:ok` for the Story 11a default `"{media_id}"` and any template
  built from a subset of the 5 placeholders plus arbitrary non-escaping
  literal separators.
  """
  @spec validate_template(String.t()) :: :ok | {:error, :invalid_key_prefix_template}
  def validate_template(template) when is_binary(template) do
    with :ok <- check_balanced_braces(template),
         tokens = Regex.scan(~r/\{[^{}]*\}/, template) |> Enum.map(&hd/1),
         :ok <- check_known_placeholders(tokens),
         :ok <- check_media_id_present(template),
         :ok <- check_no_path_escape(template) do
      :ok
    end
  end

  def validate_template(_not_a_string), do: {:error, :invalid_key_prefix_template}

  @doc """
  Story `11c-s3-key-prefix-template` AC2/AC3: interpolates `template` into an
  actual S3 object key. Called from **exactly one** call site — the upload
  path of `Nebu.Media` (`lib/nebu/media.ex`), immediately before
  `Storage.put/2`.

  `attrs` is `%{media_id:, server_name:, uploaded_at: %DateTime{}}`.
  `{year}`/`{month}`/`{day}` are the UTC calendar date of `uploaded_at`
  (`Calendar.strftime/2`, zero-padded for month/day).

  Deliberately does **not** re-validate `template` — AC5's whole point is
  that an invalid template never reaches `media_storage_config` in the first
  place (`validate_template/1` runs once, at `upsert/1` time). Adding a
  second, possibly-diverging validation branch here is explicitly
  disallowed by the story's Dev Agent Guardrails.
  """
  @spec compute_key(String.t(), map()) :: String.t()
  def compute_key(template, %{media_id: media_id, server_name: server_name, uploaded_at: %DateTime{} = dt}) do
    template
    |> String.replace("{media_id}", media_id)
    |> String.replace("{server_name}", server_name)
    |> String.replace("{year}", Calendar.strftime(dt, "%Y"))
    |> String.replace("{month}", Calendar.strftime(dt, "%m"))
    |> String.replace("{day}", Calendar.strftime(dt, "%d"))
  end

  # ── validate_template/1 internals ────────────────────────────────────────

  # No placeholder ever nests, so a correct brace-balance check is simply:
  # every '{' must be closed by the very next '}' before another '{'
  # appears, and vice versa — i.e. depth never exceeds 1 and returns to 0
  # at the end.
  defp check_balanced_braces(template) do
    template
    |> String.to_charlist()
    |> Enum.reduce_while(0, fn
      ?{, 0 -> {:cont, 1}
      ?{, 1 -> {:halt, :unbalanced}
      ?}, 1 -> {:cont, 0}
      ?}, 0 -> {:halt, :unbalanced}
      _other, depth -> {:cont, depth}
    end)
    |> case do
      0 -> :ok
      _ -> {:error, :invalid_key_prefix_template}
    end
  end

  defp check_known_placeholders(tokens) do
    if Enum.all?(tokens, &(&1 in @placeholders)) do
      :ok
    else
      {:error, :invalid_key_prefix_template}
    end
  end

  defp check_media_id_present(template) do
    if String.contains?(template, "{media_id}") do
      :ok
    else
      {:error, :invalid_key_prefix_template}
    end
  end

  # Splits the raw template on every recognized placeholder span, yielding
  # only the LITERAL text that surrounds/separates placeholders (the
  # placeholder tokens themselves disappear from the split — they are never
  # part of any segment). Each literal segment is then checked in ISOLATION.
  #
  # This is deliberately NOT "strip placeholders then concatenate": doing
  # that collapses the `/` separators that legitimately sit *between*
  # adjacent placeholders (e.g. "{year}/{month}/{day}/{server_name}/{media_id}")
  # into false double/triple-slashes, rejecting every valid hierarchical
  # template. Checking each segment on its own avoids that: a `/` at the end
  # of one segment and a `/` at the start of the next segment are two
  # DIFFERENT segments (separated by a placeholder that was never part of
  # either), so they never combine into a literal "//" — only a genuine `//`
  # written directly in the template's literal text (with no placeholder
  # between the two slashes) ever lands inside a single segment.
  #
  # Run AFTER check_known_placeholders/1, so only genuine, recognized
  # placeholder tokens are ever split out.
  defp check_no_path_escape(template) do
    segments = Regex.split(~r/\{[^{}]*\}/, template)

    leading_slash? =
      case segments do
        [first | _] -> String.starts_with?(first, "/")
        [] -> false
      end

    has_dotdot? = Enum.any?(segments, &String.contains?(&1, ".."))
    has_double_slash? = Enum.any?(segments, &String.contains?(&1, "//"))

    if leading_slash? or has_dotdot? or has_double_slash? do
      {:error, :invalid_key_prefix_template}
    else
      :ok
    end
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @doc """
  Ensures a running, SUPERVISED instance is registered under `__MODULE__` and
  returns its pid.

  `Nebu.Media.StorageConfig.Supervisor` starts its child via
  `raw_start_link/1` directly (see that module's `init/1`) — never via this
  function, to avoid calling back into the very supervisor that is still in
  the middle of starting it. Every OTHER caller (e.g. a test's own
  `ensure_started/0` helper) goes through here: if the supervised child is
  currently stopped (its `:transient` restart type does not auto-restart a
  NORMAL exit), `Supervisor.restart_child/2` brings it back up SYNCHRONOUSLY
  as a genuine child of that supervisor before returning — never a bare,
  unsupervised process sharing the registered name. Falls back to a raw,
  unsupervised start only if the dedicated supervisor itself is not running.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    case Supervisor.restart_child(Nebu.Media.StorageConfig.Supervisor, __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, :running} -> {:error, {:already_started, Process.whereis(__MODULE__)}}
      {:error, :restarting} -> {:error, :restarting}
      {:error, _reason} -> raw_start_link(opts)
    end
  catch
    :exit, _ -> raw_start_link(opts)
  end

  @doc false
  @spec raw_start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def raw_start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    ensure_pg()
    :pg.join(@pg_group, self())
    ensure_table()
    do_refresh()
    schedule_ttl_tick()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    do_refresh()
    broadcast()
    {:reply, :ok, state}
  end

  # A peer node broadcast an invalidation (or our own upsert/1 triggered one
  # via handle_call(:refresh, ...) above already re-read locally on THIS
  # node) — re-read locally.
  @impl GenServer
  def handle_info({:invalidate_media_storage_config}, state) do
    do_refresh()
    {:noreply, state}
  end

  # AC7 TTL fallback: force a re-read every @ttl_ms regardless of whether a
  # :pg broadcast was received, so a partitioned/missed-broadcast node cannot
  # serve a stale endpoint/credential indefinitely.
  @impl GenServer
  def handle_info(:ttl_tick, state) do
    do_refresh()
    schedule_ttl_tick()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Robustness fix (story 11b-storage-ui-test-connection): `upsert/2`'s
  # write already succeeded via `writer.()` by the time this runs — a
  # missing/stopped singleton (e.g. a NORMAL `GenServer.stop/1` exit, which
  # this process's `:transient` restart strategy does not auto-restart, per
  # `start_link/0`'s own moduledoc) must never turn an already-successful DB
  # write into a crashed request just because the cache-refresh step had no
  # process to call. Reuses `start_link/0`'s own sanctioned
  # `Supervisor.restart_child/2`-then-raw-start fallback (the same path this
  # module's moduledoc already documents for "a test's own ensure_started/0
  # helper") to bring the singleton back before refreshing it.
  defp refresh_cache do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, pid} -> GenServer.call(pid, :refresh)
          {:error, {:already_started, pid}} when is_pid(pid) -> GenServer.call(pid, :refresh)
          _ -> :ok
        end

      pid ->
        GenServer.call(pid, :refresh)
    end
  catch
    :exit, _ -> :ok
  end

  # ── Write path internals ─────────────────────────────────────────────────

  # Only the columns present in `fields` are included — this is what makes
  # upsert/1's DB write a genuine partial UPDATE (AT6). access_key/secret_key
  # are encrypted here, before the DB write, via the ONE sanctioned
  # Nebu.Web.SecretBox primitive — a raise from SecretBox.encrypt/1 (no
  # at-rest secret configured) propagates straight out of upsert/1 (AT12), it
  # is never caught/swallowed.
  defp build_columns(fields) do
    Enum.reduce(fields, %{}, fn {key, value}, acc ->
      case column_for(key, value) do
        {column, encoded} -> Map.put(acc, column, encoded)
        nil -> acc
      end
    end)
  end

  defp column_for(:access_key, nil), do: {"access_key_encrypted", nil}
  defp column_for(:access_key, value) when is_binary(value), do: {"access_key_encrypted", SecretBox.encrypt(value)}
  defp column_for(:secret_key, nil), do: {"secret_key_encrypted", nil}
  defp column_for(:secret_key, value) when is_binary(value), do: {"secret_key_encrypted", SecretBox.encrypt(value)}
  defp column_for(:endpoint, value), do: {"endpoint", value}
  defp column_for(:bucket, value), do: {"bucket", value}
  defp column_for(:region, value), do: {"region", value}
  defp column_for(:use_ssl, value), do: {"use_ssl", value}
  defp column_for(:s3_key_prefix_template, value), do: {"s3_key_prefix_template", value}
  defp column_for(:archive_bucket, value), do: {"archive_bucket", value}
  # bugfix-add-sts-iam-endpoints-to-admin-ui (AC1): DB-override columns added
  # by migration 000037 — same plain pass-through shape as every other
  # non-secret field above.
  defp column_for(:iam_endpoint, value), do: {"iam_endpoint", value}
  defp column_for(:sts_endpoint, value), do: {"sts_endpoint", value}
  defp column_for(_unknown_key, _value), do: nil

  # The plain fields of `fields` (atom key => column name) that can be compared with the row before the write. The
  # keys are not: a submitted key always counts as changed (the stored ciphertext cannot be compared with a plaintext).
  @plain_columns %{
    endpoint: "endpoint",
    use_ssl: "use_ssl",
    bucket: "bucket",
    region: "region",
    s3_key_prefix_template: "s3_key_prefix_template",
    archive_bucket: "archive_bucket",
    iam_endpoint: "iam_endpoint",
    sts_endpoint: "sts_endpoint"
  }

  # The field names (atoms, no values) whose submitted value differs from the row as it was read before the write. No
  # row, or a row that could not be read: every submitted field. A save that carries keys also writes `endpoint` and
  # `use_ssl` (the controller pins the target to the keys), which are not named when they equal the stored values.
  defp changed_fields(fields, {:ok, row}) when is_map(row) do
    fields
    |> Enum.filter(fn {key, value} ->
      case Map.fetch(@plain_columns, key) do
        {:ok, column} -> Map.get(row, column) != value
        :error -> true
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp changed_fields(fields, _no_row), do: Map.keys(fields)

  # Both keys blank (empty or whitespace), or one blank and one `nil`, is "no keys submitted": no key column is
  # written (`SecretBox.encrypt("")` would store an empty secret) and the keys are not named in the audit; the other
  # fields are saved as usual. Both `nil` stays the explicit clear of the pair; exactly one usable key is refused by
  # `validate_key_pair/1`.
  defp without_blank_keys(fields) do
    keys = [Map.get(fields, :access_key, :absent), Map.get(fields, :secret_key, :absent)]

    if :absent not in keys and keys != [nil, nil] and not Enum.any?(keys, &present_key?/1) do
      Map.drop(fields, [:access_key, :secret_key])
    else
      fields
    end
  end

  # AC9: metadata records ONLY which field names changed, never their values
  # (secret or not): `changed_fields/2` hands over atoms only, no value, secret
  # or plain, ever reaches this function (write_audit/2 itself never
  # touches `columns`/ciphertext/plaintext at all).
  defp write_audit(actor, changed) do
    case AuditWriter.log(
           actor,
           @audit_action,
           @audit_target_type,
           @audit_target_id,
           %{changed_fields: changed},
           "success"
         ) do
      :ok ->
        :ok

      {:error, audit_reason} ->
        Logger.error(
          "Nebu.Media.StorageConfig: media_storage_config_updated audit write failed " <>
            "after successful config write actor=#{inspect(actor)} " <>
            "reason=#{inspect(audit_reason)}"
        )
    end
  end

  # ── Read path internals ─────────────────────────────────────────────────

  # The only place `build_resolved/2` (and therefore `SecretBox.decrypt/1`)
  # is called from the read path — both `get/0` and `get_for_connection/0`
  # go through this function, so decryption happens ON DEMAND on every read,
  # never while building/refreshing the ETS-cached catalog (see
  # `row_and_env/0`/`do_refresh/0` below — MINOR-1 fix).
  defp resolved do
    {row, env} = row_and_env()
    build_resolved(row, env)
  end

  # Returns the RAW ingredients: the DB row (still `Nebu.Web.SecretBox`
  # ciphertext for `access_key_encrypted`/`secret_key_encrypted`, or `nil`)
  # and the raw env-var map. Never a decrypted secret — that only happens in
  # `build_resolved/2`, called directly by `resolved/0` above.
  #
  # Test-seam fix (story 11b-storage-ui-test-connection): the cached snapshot
  # is tagged with the EXACT `:media_storage_config_loader`/
  # `:media_storage_env_reader` `Application.get_env/2` values that produced
  # it. A cache hit is only served when BOTH still match the CURRENT seam
  # values (Erlang fun terms compare by identity of code+captured
  # environment, so two distinct anonymous functions — e.g. one set up by
  # THIS test, one left over from a PREVIOUS test/boot — never match, while
  # the SAME closure across repeated calls always does). This makes a fresh
  # `Application.put_env(:nebu_http, :media_storage_config_loader, fn -> ...
  # end)` in a NEW test observable immediately, without requiring an
  # explicit `:refresh`/`:ttl_tick` — while a test that installs ONE seam
  # once and only mutates data BEHIND it (e.g. AT11's TTL-fallback test,
  # which never changes the loader closure itself, only an Agent it reads)
  # still correctly observes the STALE cached value until a genuine
  # refresh — the seam VALUE hasn't changed, only what it happens to
  # return. Production (neither seam ever configured, both `nil` on every
  # call) is completely unaffected: `nil == nil` always matches, so the
  # ETS-cache-first hot path (this module's whole reason for existing, per
  # its moduledoc) is unchanged for every real deployment.
  #
  # A row that CANNOT be read (see `load_row/0`) is not "no row": `read_snapshot/0` reports it, and this lenient
  # variant (`get/0`, `get_for_connection/0`, which always answer a map) then shows the environment / defaults.
  defp row_and_env do
    case read_snapshot() do
      {:ok, snapshot} -> snapshot
      {:error, :storage_config_unavailable} -> {nil, safe_env()}
    end
  end

  # `{:ok, {row, env}}` from the cache, else from a direct read; `{:error, :storage_config_unavailable}` when there is
  # no usable snapshot and the row cannot be read. The operational path (`request_target/0`) must not fall back to the
  # environment target then, as a saved target may well exist.
  defp read_snapshot do
    case cached_snapshot() do
      {:ok, _snapshot} = hit ->
        hit

      :miss ->
        with {:ok, row} <- load_row(), do: {:ok, {row, safe_env()}}
    end
  end

  defp cached_snapshot do
    case :ets.lookup(@table, :catalog) do
      [{:catalog, {row, env, loader_seam, env_seam}}] ->
        if loader_seam == current_loader_seam() and env_seam == current_env_seam(), do: {:ok, {row, env}}, else: :miss

      _ ->
        :miss
    end
  rescue
    # the cache table does not exist (the cache process is not running)
    ArgumentError -> :miss
  end

  defp current_loader_seam, do: Application.get_env(:nebu_http, :media_storage_config_loader)
  defp current_env_seam, do: Application.get_env(:nebu_http, :media_storage_env_reader)

  # Refreshes the cached RAW ingredients only — no `SecretBox.decrypt/1` call
  # here. This is what the GenServer's `:ttl_tick`/`:pg`-invalidation refresh
  # path runs, so (a) no plaintext secret is ever written into the
  # `:protected` ETS table, and (b) a corrupted ciphertext or an unset
  # at-rest key can never crash this periodic refresh (MINOR-1/MINOR-2(b)).
  # Tags the snapshot with the seam values that produced it — see
  # `row_and_env/0` above.
  #
  # A refresh that cannot read the row keeps the last good snapshot (the next refresh retries): replacing it with "no
  # row" would send every operational call to the environment target until then. Only a confirmed absent row (`nil`)
  # replaces the snapshot.
  defp do_refresh do
    case load_row() do
      {:ok, row} -> :ets.insert(@table, {:catalog, {row, safe_env(), current_loader_seam(), current_env_seam()}})
      {:error, :storage_config_unavailable} -> :ok
    end
  end

  # `{:ok, row | nil}` (`nil`: the row is confirmed absent) or `{:error, :storage_config_unavailable}`: the loader seam
  # answered `{:error, _}` or raised (the default loader answers `{:error, _}` for a failed query or an unavailable Repo).
  defp load_row do
    loader = Application.get_env(:nebu_http, :media_storage_config_loader, &default_loader/0)

    case loader.() do
      map when is_map(map) -> {:ok, map}
      {:error, _reason} -> {:error, :storage_config_unavailable}
      _ -> {:ok, nil}
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.StorageConfig: loader raised: #{inspect(e)}")
      {:error, :storage_config_unavailable}
  end

  # The row for the callers that treat an unreadable row as "no row" (the orphan-risk baselines of the admin form).
  defp safe_load do
    case load_row() do
      {:ok, row} -> row
      {:error, :storage_config_unavailable} -> nil
    end
  end

  defp safe_env do
    reader = Application.get_env(:nebu_http, :media_storage_env_reader, &default_env_reader/0)

    case reader.() do
      map when is_map(map) -> map
      _ -> %{}
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.StorageConfig: env reader raised: #{inspect(e)}")
      %{}
  end

  # Builds the unmasked, plaintext-secret catalog (AC4/AC5): DB row value >
  # env-var fallback > compiled default, per field. `row` is `nil` (no row
  # ever written) or a STRING-keyed map of column values. `env` is a
  # STRING-keyed map standing in for NEBU_MINIO_*/NEBU_S3_REGION.
  #
  # The secrets are exactly the pair the operational path would sign with (`operation_credentials/2`): the saved pair,
  # or the environment's for the environment's own target. For a half pair, undecryptable or unreadable keys, or another
  # endpoint without saved keys there is no key (`nil`, "Not currently configured." on the settings page), so the page
  # never presents env keys as the credentials of another saved endpoint nor mixes a saved key with an env key. A read
  # never raises and logs nothing here: the operational path reports an unusable pair once per operation.
  defp build_resolved(row, env) do
    {access_key, secret_key} =
      case operation_credentials(row, env) do
        {:ok, access_key, secret_key} -> {blank_to_nil(access_key), blank_to_nil(secret_key)}
        {:error, _reason} -> {nil, nil}
      end

    Map.merge(plain_fields(row, env), %{access_key: access_key, secret_key: secret_key})
  end

  # `build_resolved/2` without the two secrets: what is needed to address a request (and to compare targets) and
  # never decrypts or reads a secret file.
  defp plain_fields(row, env) do
    %{
      endpoint: pick(row_get(row, "endpoint"), Map.get(env, "NEBU_MINIO_ENDPOINT"), @defaults.endpoint),
      bucket: pick(row_get(row, "bucket"), Map.get(env, "NEBU_MINIO_BUCKET"), @defaults.bucket),
      region: pick(row_get(row, "region"), Map.get(env, "NEBU_S3_REGION"), @defaults.region),
      use_ssl:
        pick(
          row_get(row, "use_ssl"),
          parse_bool(Map.get(env, "NEBU_MINIO_USE_SSL")),
          @defaults.use_ssl
        ),
      s3_key_prefix_template:
        pick(row_get(row, "s3_key_prefix_template"), nil, @defaults.s3_key_prefix_template),
      archive_bucket: pick(row_get(row, "archive_bucket"), nil, @defaults.archive_bucket),
      # bugfix-add-sts-iam-endpoints-to-admin-ui (AC1): DB row (migration
      # 000037's iam_endpoint/sts_endpoint columns) > env-var fallback >
      # compiled default — same precedence as every other plain field above.
      # Full URLs (scheme + port + path), so NOT run through
      # validate_candidate_endpoint/1 — that function's scheme-rejection is
      # specific to `endpoint`'s bare host[:port] contract. The WRITE path
      # (a non-nil value reaching upsert/1) is validated separately by
      # validate_iam_sts_fields/1 — this READ path never re-validates an
      # already-resolved value, DB-, env-, or default-sourced alike.
      iam_endpoint: pick(row_get(row, "iam_endpoint"), Map.get(env, "NEBU_MINIO_IAM_ENDPOINT"), @defaults.iam_endpoint),
      sts_endpoint: pick(row_get(row, "sts_endpoint"), Map.get(env, "NEBU_MINIO_STS_ENDPOINT"), @defaults.sts_endpoint)
    }
  end

  defp row_get(nil, _key), do: nil
  defp row_get(row, key) when is_map(row), do: Map.get(row, key)

  # Per-field precedence (AC5): DB value wins over the env-var fallback wins
  # over the compiled default — explicit `false` (use_ssl) is a legitimate
  # DB/env value, not "unset", so this must NOT be a plain `||` chain.
  defp pick(db_value, fallback_value, default) do
    cond do
      not is_nil(db_value) -> db_value
      not is_nil(fallback_value) -> fallback_value
      true -> default
    end
  end

  defp parse_bool(nil), do: nil
  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool(value) when is_binary(value), do: value == "true"

  # Mirrors server/config/runtime.exs lines 85-95's `_FILE`-then-plain
  # precedence exactly: a Docker-secret-file path wins over the
  # simultaneously-set plain env var (AT3).
  defp resolve_env_secret(env, file_key, plain_key) do
    case Map.get(env, file_key) do
      nil -> Map.get(env, plain_key)
      path -> path |> File.read!() |> String.trim()
    end
  end

  defp merge_over_defaults(override) when is_map(override), do: Map.merge(@defaults, override)
  defp merge_over_defaults(_), do: @defaults

  # AC8: mask access_key/secret_key. `nil` (genuinely unset) stays `nil`; a
  # non-empty plaintext becomes "••••" <> last 4 chars — the format this
  # module's own test suite pins exactly.
  defp mask_map(map) do
    %{map | access_key: mask_secret(map.access_key), secret_key: mask_secret(map.secret_key)}
  end

  defp mask_secret(nil), do: nil
  defp mask_secret(""), do: nil

  defp mask_secret(plaintext) when is_binary(plaintext) do
    "••••" <> String.slice(plaintext, -4..-1)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp schedule_ttl_tick do
    Process.send_after(self(), :ttl_tick, @ttl_ms)
  end

  defp broadcast do
    self_pid = self()

    for pid <- :pg.get_members(@pg_group), pid != self_pid do
      send(pid, {:invalidate_media_storage_config})
    end

    :ok
  end

  defp ensure_pg do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end

  # ── Default (real) DB read/write/env — only exercised when no test seam is set ──

  @sql_load_media_storage_config """
  SELECT endpoint, bucket, region, use_ssl, access_key_encrypted,
         secret_key_encrypted, s3_key_prefix_template, archive_bucket,
         iam_endpoint, sts_endpoint, set_at
  FROM media_storage_config
  WHERE id = 1
  """

  # `nil` only for a confirmed absent row; a failed query or an unavailable Repo is an `{:error, _}` (see `load_row/0`).
  defp default_loader do
    if Process.whereis(Nebu.Repo) != nil do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_media_storage_config, []) do
        {:ok, %{rows: [row], columns: columns}} ->
          Enum.zip(columns, row) |> Map.new()

        {:ok, %{rows: []}} ->
          nil

        {:error, reason} ->
          Logger.warning("Nebu.Media.StorageConfig: failed to load media_storage_config: #{inspect(reason)}")
          {:error, :load_failed}
      end
    else
      {:error, :repo_unavailable}
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.StorageConfig: unexpected error loading media_storage_config: #{inspect(e)}")
      {:error, :load_failed}
  end

  # Dynamic partial column list built ONLY from `columns`' own keys — never
  # from unsanitized external input; `columns` is always produced by
  # build_columns/1's fixed, hardcoded column-name mapping above, never by a
  # caller-supplied string, so this is not a SQL-injection surface.
  defp default_writer(columns, set_at) do
    pairs = Map.to_list(columns) ++ [{"set_at", set_at}]
    cols = Enum.map(pairs, &elem(&1, 0))
    vals = Enum.map(pairs, &elem(&1, 1))

    insert_cols = ["id" | cols]
    insert_vals = [1 | vals]
    placeholders = for i <- 1..length(insert_cols), do: "$#{i}"

    update_set =
      cols
      |> Enum.with_index(2)
      |> Enum.map(fn {col, idx} -> "#{col} = $#{idx}" end)
      |> Enum.join(", ")

    sql = """
    INSERT INTO media_storage_config (#{Enum.join(insert_cols, ", ")})
    VALUES (#{Enum.join(placeholders, ", ")})
    ON CONFLICT (id) DO UPDATE SET #{update_set}
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, insert_vals) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # ── Test Connection internals (story 11b) ────────────────────────────────

  # M-1/M-2/M-3 (SSRF + transport-downgrade; M-1 forward-carried from the 11a
  # security review, M-2/M-3 fixed per the epic-end security review,
  # 2026-07-20): `runtime.exs`'s NEBU_MINIO_ENDPOINT and this module's own
  # env-var-fallback reader both use a bare `host[:port]` contract, never a
  # URL with a scheme. A candidate carrying `http://`/`https://` would let an
  # admin (or a request that reached this far with attacker-influenced
  # input) silently redirect the real ExAws HTTP client's scheme/host
  # resolution in a way `config_overrides/1` below does not expect — reject
  # it before any request is built.
  #
  # Beyond the scheme check, the resolved host is now also run through the
  # SAME shared `Nebu.Media.SSRF.checked_target/1` guard `preview_url` and
  # both webhook paths already use (`Nebu.Media.WebhookDelivery.post/2`) —
  # closing M-2 (this function is called from `test_connection/1`, BEFORE any
  # real ExAws `head_bucket` request is issued) and M-3 (this function is ALSO
  # called from `upsert/1`'s `validate_endpoint_field/1`, BEFORE any DB write,
  # so a private/loopback/link-local/CGNAT/cloud-metadata endpoint can no
  # longer be persisted at all — not even by skipping test-connection).
  # `SSRF.checked_target/1` expects a full URL with a scheme; since this
  # module's own contract is a bare `host[:port]`, a synthetic `http://`
  # prefix is prepended purely to satisfy `URI.parse/1` — the scheme itself
  # is irrelevant to the private/loopback/link-local/metadata IP check that
  # follows, and the real ExAws request still uses `candidate.use_ssl`/
  # `config_overrides/1` to pick the actual transport scheme, unaffected by
  # this synthetic one.
  #
  # storage-test-pinned-target D1: returns `{:ok, %{scheme, host, ip}}`, the checked target (the host resolved ONCE),
  # instead of discarding it; `test_connection/1` carries it to the request, `upsert/1` ignores it (no request).
  defp validate_candidate_endpoint(endpoint) when is_binary(endpoint) do
    downcased = String.downcase(endpoint)

    cond do
      String.starts_with?(downcased, "http://") or String.starts_with?(downcased, "https://") ->
        {:error, :invalid_endpoint}

      # a bare `host[:port]` never carries user info (`user@host`): it would be signed into the Host value and could make the
      # host the SSRF check resolved differ from the one a reader of the endpoint sees (storage-test-pinned-target, Kassandra INFO-2)
      String.contains?(endpoint, "@") ->
        {:error, :invalid_endpoint}

      # what the operational parser would reject later (a path, an IPv6 literal, a bad port) must not be saved or tested
      unparsable_endpoint?(endpoint) ->
        {:error, :invalid_endpoint}

      true ->
        case SSRF.checked_target("http://" <> endpoint, allow_private: SSRF.allow_private_storage?()) do
          {:ok, target} ->
            {:ok, target}

          {:error, reason} ->
            Logger.warning(
              "Nebu.Media.StorageConfig: storage endpoint #{inspect(endpoint)} rejected: " <>
                SSRF.describe_error(reason)
            )

            {:error, :invalid_endpoint}
        end
    end
  end

  defp validate_candidate_endpoint(_), do: {:error, :invalid_endpoint}

  @doc """
  Admin-facing explanation of why `endpoint` failed `validate_candidate_endpoint/1`
  (`{:error, :invalid_endpoint}` carries no detail). Re-runs the check on the
  error path only, so the happy path pays no extra DNS lookup.
  """
  @spec describe_invalid_endpoint(term()) :: String.t()
  def describe_invalid_endpoint(endpoint) when is_binary(endpoint) do
    downcased = String.downcase(endpoint)

    if String.starts_with?(downcased, "http://") or String.starts_with?(downcased, "https://") do
      "Endpoint must be a bare host[:port] value (no http:// or https:// scheme prefix)."
    else
      cond do
        String.contains?(endpoint, "@") ->
          "Endpoint must be a bare host[:port] value (no user info before an @)."

        unparsable_endpoint?(endpoint) ->
          "Endpoint must be a host name or IPv4 address, optionally followed by :port (1 to 65535); no path, no IPv6 literal."

        true ->
          case SSRF.checked_target("http://" <> endpoint, allow_private: SSRF.allow_private_storage?()) do
            {:ok, _target} -> "Endpoint is not valid."
            {:error, reason} -> "Endpoint rejected: " <> SSRF.describe_error(reason) <> "."
          end
      end
    end
  end

  def describe_invalid_endpoint(_), do: "Endpoint must be a bare host[:port] value."

  defp unparsable_endpoint?(endpoint), do: match?({:error, _reason}, parse_endpoint(endpoint, false))

  # AC3: any blank secret in the candidate is resolved against the
  # CURRENTLY stored decrypted secret — this is
  # the only place a decrypted secret is attached to a candidate map handed
  # to the test-connection fun; the resolved plaintext never round-trips
  # back to the controller/browser (the fun's return value is just :ok /
  # {:error, reason}).
  defp resolve_candidate_secrets(candidate) do
    access_key = blank_to_nil(Map.get(candidate, :access_key))
    secret_key = blank_to_nil(Map.get(candidate, :secret_key))

    if is_nil(access_key) or is_nil(secret_key) do
      # story admin-forms-gate-sweep D4 (Kassandra design review): a stored credential signs a request to the STORED target only. Reusing it for an endpoint (or a
      # scheme) the form supplies would hand the access key id and a signature (an offline guessing oracle for the secret) to a host the credentials were never meant
      # for. The IAM / STS endpoints are not compared: the test never contacts them (they join the comparison if it ever does).
      # The stored credentials are those the operational path would use for that target (`operation_credentials/2`): the saved
      # pair, or the environment's for the environment's own target, never the environment's for another saved endpoint.
      with {:ok, {row, env}} <- read_snapshot(),
           true <- same_target?(candidate, plain_fields(row, env)),
           {:ok, stored_access_key, stored_secret_key} <- operation_credentials(row, env) do
        {:ok, %{candidate | access_key: access_key || stored_access_key, secret_key: secret_key || stored_secret_key}}
      else
        _ -> {:error, :secret_required}
      end
    else
      {:ok, %{candidate | access_key: access_key, secret_key: secret_key}}
    end
  end

  defp same_target?(candidate, stored) do
    normalize_endpoint(Map.get(candidate, :endpoint)) == normalize_endpoint(Map.get(stored, :endpoint)) and
      (Map.get(candidate, :use_ssl) == true) == (Map.get(stored, :use_ssl) == true)
  end

  defp normalize_endpoint(endpoint) when is_binary(endpoint), do: endpoint |> String.trim() |> String.downcase(:ascii)
  defp normalize_endpoint(_other), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Production default: a single S3 HEAD against the candidate bucket root
  # (not put_object/get_object), using ExAws's per-request config-override
  # keyword list built from the CANDIDATE values (never the currently-active
  # Application-env-configured connection `Nebu.Media.Storage` uses) — so
  # this exercises exactly what would be saved. `ExAws.S3.head_bucket/1` (the
  # story's own Technical Requirement) is the pinned `ex_aws_s3` version's
  # public helper for exactly this operation.
  defp default_test_connection(candidate) do
    with {:ok, overrides} <- config_overrides(candidate),
         {:ok, _response} <- candidate.bucket |> ExAws.S3.head_bucket() |> ExAws.request(overrides) do
      :ok
    end
  rescue
    e -> {:error, e}
  end

  # storage-test-pinned-target D2: `http_client` / `http_opts` select the pin client for THIS request only (the operational
  # `Nebu.Media.Storage` calls, see `request_target/0`, keep the configured HTTP client). `http_opts` carries the checked target; the client
  # fails closed when it is missing (`Map.get/2`: a candidate without `:pinned_target` ends in an error, never in a
  # normal request).
  defp config_overrides(candidate) do
    with {:ok, host, port} <- parse_endpoint(candidate.endpoint, candidate.use_ssl) do
      {:ok,
       connection_overrides(host, port, candidate) ++
         [
           http_client: Nebu.Media.PinnedHttpClient,
           http_opts: [pinned_target: Map.get(candidate, :pinned_target)],
           # ONE attempt for the admin test (this override only; the operational calls keep the configured retries): ExAws would
           # otherwise repeat a refused / failed pinned request up to `max_attempts` times with a growing backoff while the admin waits.
           retries: [max_attempts: 1, base_backoff_in_ms: 1, max_backoff_in_ms: 1]
         ]}
    end
  end

  # The per-request ExAws overrides both the Test Connection and the operational calls (`request_target/0`) share.
  defp connection_overrides(host, port, cfg) do
    [
      access_key_id: cfg.access_key,
      secret_access_key: cfg.secret_key,
      host: host,
      scheme: if(ssl?(cfg.use_ssl), do: "https://", else: "http://"),
      port: port,
      region: cfg.region
    ]
  end

  defp ssl?(use_ssl), do: use_ssl == true
  defp default_port(use_ssl), do: if(ssl?(use_ssl), do: 443, else: 80)

  # THE `host[:port]` parser: save validation, Test Connection and every operational request decide with it what an
  # endpoint is, so none of them accepts a value another one rejects. The port defaults to 443/80 by scheme (as
  # `runtime.exs` does). Never raises: the saved endpoint is admin input and `NEBU_MINIO_ENDPOINT` may be set empty.
  # `{:error, :storage_endpoint_blank}`: no host. `{:error, :storage_endpoint_invalid}`: a path, an IPv6 literal, a port
  # that is not a number from 1 to 65535 or any other character that does not belong to a host name.
  defp parse_endpoint(endpoint, use_ssl) when is_binary(endpoint) do
    case endpoint |> String.trim() |> String.split(":", parts: 2) do
      [host, port] -> parse_host_port(String.trim(host), String.trim(port))
      [host] -> parse_host_port(String.trim(host), default_port(use_ssl))
    end
  end

  defp parse_endpoint(_endpoint, _use_ssl), do: {:error, :storage_endpoint_blank}

  defp parse_host_port("", _port), do: {:error, :storage_endpoint_blank}

  defp parse_host_port(host, port) when is_binary(port) do
    case Integer.parse(port) do
      {number, ""} -> parse_host_port(host, number)
      _ -> {:error, :storage_endpoint_invalid}
    end
  end

  defp parse_host_port(host, port) when port in 1..65_535 do
    if host =~ ~r/\A[A-Za-z0-9._-]+\z/, do: {:ok, host, port}, else: {:error, :storage_endpoint_invalid}
  end

  defp parse_host_port(_host, _port), do: {:error, :storage_endpoint_invalid}

  # Mirrors server/config/runtime.exs lines 78-119's own NEBU_MINIO_*/
  # NEBU_S3_REGION reads exactly. Any absent var is simply not put into the
  # map — "any absent/nil key means not set", matching System.get_env/1's own
  # nil-when-unset contract.
  defp default_env_reader do
    %{}
    |> maybe_put_env("NEBU_MINIO_ENDPOINT")
    |> maybe_put_env("NEBU_MINIO_USE_SSL")
    |> maybe_put_env("NEBU_MINIO_BUCKET")
    |> maybe_put_env("NEBU_S3_REGION")
    |> maybe_put_env("NEBU_MINIO_ACCESS_KEY_FILE")
    |> maybe_put_env("NEBU_MINIO_ACCESS_KEY")
    |> maybe_put_env("NEBU_MINIO_SECRET_KEY_FILE")
    |> maybe_put_env("NEBU_MINIO_SECRET_KEY")
    # bugfix-upcloud-s3-iam-sts-endpoints (AC1): UpCloud Managed Object
    # Storage's separate IAM/STS endpoint URLs, mirroring runtime.exs's own
    # NEBU_MINIO_IAM_ENDPOINT/NEBU_MINIO_STS_ENDPOINT reads (AC2).
    |> maybe_put_env("NEBU_MINIO_IAM_ENDPOINT")
    |> maybe_put_env("NEBU_MINIO_STS_ENDPOINT")
  end

  defp maybe_put_env(map, key) do
    case System.get_env(key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end
end
