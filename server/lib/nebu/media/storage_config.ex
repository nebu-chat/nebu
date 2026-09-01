defmodule Nebu.Media.StorageConfig do
  @moduledoc """
  ETS-backed cache for the singleton `media_storage_config` table (story
  `media-security-admin-control/11a-storage-config-schema-secrets`).

  ## Purpose

  Since ADR-INFRA-0 (`Nebu.Media.Storage`, pre-epic), the S3/MinIO storage
  target has been wired exclusively through boot-time `NEBU_MINIO_*`/
  `NEBU_S3_REGION` env vars in `server/config/runtime.exs`. This module adds
  an admin-configurable override for the same target, with `access_key`/
  `secret_key` encrypted at rest via `Nebu.Web.SecretBox` (never a second,
  parallel AES helper — see the story's Dev Agent Guardrails).

  This is a **separate** cache instance from `Nebu.Media.Config` (Story 9a) —
  its own ETS table (`:nebu_media_storage_config`), its own `:pg` group
  (`"nebu_media_storage_config"`), never shared, per the story's Summary:
  storage-target changes are rare/security-sensitive and must never couple to
  `media_config`'s hot-path invalidation group.

  ## Interface

  - `get/0` — the merged config map (DB row > env-var fallback > compiled
    default, per field), with `access_key`/`secret_key` **masked** (AC8).
    Never returns a decrypted secret.
  - `get_for_connection/0` — same merge, but `access_key`/`secret_key` are
    decrypted to plaintext via `Nebu.Web.SecretBox.decrypt/1`. The only
    sanctioned way to obtain real credential bytes. Not exposed to any
    LiveView/JSON-facing surface (none exists in this story).
  - `upsert/1` — `upsert(%{field => value, ...})`, a partial-update map. The
    ONLY write path to `media_storage_config`. Rejects an `endpoint` in
    `fields` the same way `test_connection/1` does (see below) BEFORE any DB
    write — fixed post-epic per Kassandra's epic-end security review finding
    M-3 (2026-07-20): previously `endpoint` was stored verbatim with no
    validation at all on this path.
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
    written. Consulted by the GenServer's DB-refresh step AND directly by
    `get/0`/`get_for_connection/0` whenever the ETS table is not yet
    populated. Defaults to a real `SELECT ... FROM media_storage_config` when
    unset.
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
    archive_bucket: nil
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
  **decrypted to plaintext**. The only sanctioned way to obtain real
  credential bytes — intended for actual `ExAws`/S3-client construction.
  Never call this from a LiveView assign, a JSON response, or any other
  admin-facing surface.
  """
  @spec get_for_connection() :: map()
  def get_for_connection do
    resolved()
  end

  @doc """
  The ONLY write path to `media_storage_config` (AC6). `fields` is a
  partial-update map — only the keys present are written; omitted fields are
  left untouched (AC5/AT6). Encrypts `access_key`/`secret_key` via
  `Nebu.Web.SecretBox.encrypt/1` before touching the DB (AC3); a fail-closed
  raise from `SecretBox.encrypt/1` propagates BEFORE any DB write (AT12). On
  success, writes a `media_storage_config_updated` audit-log entry with
  `changed_fields` naming ONLY the fields that changed — never their values
  (AC9) — then unconditionally refreshes this node's cache (and broadcasts
  the invalidation to `:pg` peers) before returning `:ok`.
  """
  @spec upsert(map(), String.t()) :: :ok | {:error, term()}
  def upsert(fields, actor \\ @audit_actor) when is_map(fields) do
    with :ok <- validate_template_field(fields),
         :ok <- validate_endpoint_field(fields) do
      columns = build_columns(fields)
      writer = Application.get_env(:nebu_http, :media_storage_config_writer, &default_writer/2)
      set_at = System.system_time(:millisecond)

      case writer.(columns, set_at) do
        :ok ->
          write_audit(actor, fields)
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
  defp validate_endpoint_field(%{endpoint: endpoint}), do: validate_candidate_endpoint(endpoint)
  defp validate_endpoint_field(_fields), do: :ok

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
  Tests connectivity against the SUBMITTED, not-yet-saved candidate
  configuration (story `11b-storage-ui-test-connection`, AC3). Never
  persists, never reaches the write path. See moduledoc for the seam and the
  SSRF/transport-downgrade endpoint guard.
  """
  @spec test_connection(map()) :: :ok | {:error, term()}
  def test_connection(candidate) when is_map(candidate) do
    with :ok <- validate_candidate_endpoint(Map.get(candidate, :endpoint)) do
      resolved = resolve_candidate_secrets(candidate)
      fun = Application.get_env(:nebu_http, :media_storage_test_connection_fun, &default_test_connection/1)
      fun.(resolved)
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
  actual S3 object key. Called from **exactly one** call site — Story 2b's
  `store_and_quarantine/...` seam, immediately before `Storage.put/2` (see
  this module's moduledoc addendum / the story's Dev Agent Record for the
  precise wiring instruction; NOT wired anywhere yet because Story 2b has not
  landed on this branch).

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
  defp column_for(_unknown_key, _value), do: nil

  # AC9: metadata records ONLY which field names changed, never their values
  # (secret or not). `fields` is the caller's own atom-keyed input map, so
  # Map.keys/1 is exactly "the field names that changed" — no value, secret
  # or plain, ever reaches this function's caller (write_audit/2 itself never
  # touches `columns`/ciphertext/plaintext at all).
  defp write_audit(actor, fields) do
    case AuditWriter.log(
           actor,
           @audit_action,
           @audit_target_type,
           @audit_target_id,
           %{changed_fields: Map.keys(fields)},
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
  defp row_and_env do
    case :ets.whereis(@table) do
      :undefined ->
        {safe_load(), safe_env()}

      _ ->
        case :ets.lookup(@table, :catalog) do
          [{:catalog, {row, env, loader_seam, env_seam}}] ->
            if loader_seam == current_loader_seam() and env_seam == current_env_seam() do
              {row, env}
            else
              {safe_load(), safe_env()}
            end

          _ ->
            {safe_load(), safe_env()}
        end
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.StorageConfig: unexpected error reading ETS table: #{inspect(e)}")
      {nil, %{}}
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
  defp do_refresh do
    row = safe_load()
    env = safe_env()
    :ets.insert(@table, {:catalog, {row, env, current_loader_seam(), current_env_seam()}})
    {row, env}
  end

  defp safe_load do
    loader = Application.get_env(:nebu_http, :media_storage_config_loader, &default_loader/0)

    case loader.() do
      map when is_map(map) -> map
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.StorageConfig: loader raised: #{inspect(e)}")
      nil
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
  defp build_resolved(row, env) do
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
      access_key:
        resolve_secret(
          row_get(row, "access_key_encrypted"),
          env,
          "NEBU_MINIO_ACCESS_KEY_FILE",
          "NEBU_MINIO_ACCESS_KEY",
          @defaults.access_key
        ),
      secret_key:
        resolve_secret(
          row_get(row, "secret_key_encrypted"),
          env,
          "NEBU_MINIO_SECRET_KEY_FILE",
          "NEBU_MINIO_SECRET_KEY",
          @defaults.secret_key
        ),
      s3_key_prefix_template:
        pick(row_get(row, "s3_key_prefix_template"), nil, @defaults.s3_key_prefix_template),
      archive_bucket: pick(row_get(row, "archive_bucket"), nil, @defaults.archive_bucket)
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

  # access_key/secret_key: DB ciphertext (decrypted) > env var (_FILE-then-
  # plain precedence, AC4/AT3) > compiled default.
  defp resolve_secret(encrypted_column, env, file_key, plain_key, default) do
    case decrypt_secret(encrypted_column) do
      nil ->
        case resolve_env_secret(env, file_key, plain_key) do
          nil -> default
          value -> value
        end

      plaintext ->
        plaintext
    end
  end

  defp decrypt_secret(nil), do: nil

  # MINOR-2(a): a corrupted ciphertext or a rotated/wrong at-rest key must not
  # silently fall back to the env-var credential — that is a security-
  # relevant substitution the admin has no other way to notice. Log (message
  # only — never the ciphertext or any decrypted fragment) before falling
  # through to the env-var/default fallback in `resolve_secret/5`.
  #
  # MINOR-2(b): a genuinely-unset at-rest secret makes `SecretBox.decrypt/1`
  # call `SecretBox.at_rest_key/0`, which RAISES by design (fail-closed).
  # That raise must not propagate out of a config *read* (`get/0`,
  # `get_for_connection/0`, or the GenServer's `:ttl_tick`/`:pg`-invalidation
  # refresh) and crash-loop this supervised process — rescue it here and
  # treat the field as if the ciphertext were absent, same as (a). This does
  # NOT affect `upsert/1`'s own `SecretBox.encrypt/1` call (`column_for/2`),
  # which still lets the identical raise propagate unguarded out of the
  # WRITE path per AT12/AC3.
  defp decrypt_secret(ciphertext) do
    case SecretBox.decrypt(ciphertext) do
      {:ok, plaintext} ->
        plaintext

      {:error, reason} ->
        Logger.warning(
          "Nebu.Media.StorageConfig: stored secret failed to decrypt (#{inspect(reason)}); " <>
            "falling back to env-var/default credential"
        )

        nil
    end
  rescue
    e in RuntimeError ->
      Logger.warning(
        "Nebu.Media.StorageConfig: at-rest secret unavailable while decrypting a stored " <>
          "secret; falling back to env-var/default credential (#{Exception.message(e)})"
      )

      nil
  end

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
         secret_key_encrypted, s3_key_prefix_template, archive_bucket, set_at
  FROM media_storage_config
  WHERE id = 1
  """

  defp default_loader do
    if Process.whereis(Nebu.Repo) != nil do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_media_storage_config, []) do
        {:ok, %{rows: [row], columns: columns}} ->
          Enum.zip(columns, row) |> Map.new()

        {:ok, %{rows: []}} ->
          nil

        {:error, reason} ->
          Logger.warning("Nebu.Media.StorageConfig: failed to load media_storage_config: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.StorageConfig: unexpected error loading media_storage_config: #{inspect(e)}")
      nil
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
  defp validate_candidate_endpoint(endpoint) when is_binary(endpoint) do
    downcased = String.downcase(endpoint)

    cond do
      String.starts_with?(downcased, "http://") or String.starts_with?(downcased, "https://") ->
        {:error, :invalid_endpoint}

      true ->
        case SSRF.checked_target("http://" <> endpoint) do
          {:ok, _target} -> :ok
          {:error, _reason} -> {:error, :invalid_endpoint}
        end
    end
  end

  defp validate_candidate_endpoint(_), do: {:error, :invalid_endpoint}

  # AC3: any blank secret in the candidate is resolved against the
  # CURRENTLY stored decrypted secret (via get_for_connection/0) — this is
  # the only place a decrypted secret is attached to a candidate map handed
  # to the test-connection fun; the resolved plaintext never round-trips
  # back to the controller/browser (the fun's return value is just :ok /
  # {:error, reason}).
  defp resolve_candidate_secrets(candidate) do
    access_key = blank_to_nil(Map.get(candidate, :access_key))
    secret_key = blank_to_nil(Map.get(candidate, :secret_key))

    if is_nil(access_key) or is_nil(secret_key) do
      stored = get_for_connection()
      %{candidate | access_key: access_key || stored.access_key, secret_key: secret_key || stored.secret_key}
    else
      %{candidate | access_key: access_key, secret_key: secret_key}
    end
  end

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
    candidate.bucket
    |> ExAws.S3.head_bucket()
    |> ExAws.request(config_overrides(candidate))
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp config_overrides(candidate) do
    {host, port} = split_endpoint(candidate.endpoint, candidate.use_ssl)

    [
      access_key_id: candidate.access_key,
      secret_access_key: candidate.secret_key,
      host: host,
      scheme: if(candidate.use_ssl, do: "https://", else: "http://"),
      port: port,
      region: candidate.region
    ]
  end

  # Mirrors server/config/runtime.exs lines 100-104's own endpoint parsing
  # exactly (bare `host[:port]`, port defaults to 443/80 by scheme when
  # omitted).
  defp split_endpoint(endpoint, use_ssl?) do
    case String.split(endpoint, ":", parts: 2) do
      [h, p] -> {h, String.to_integer(p)}
      [h] -> {h, if(use_ssl?, do: 443, else: 80)}
    end
  end

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
  end

  defp maybe_put_env(map, key) do
    case System.get_env(key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end
end
