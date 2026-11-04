defmodule Nebu.Matrix.DeviceKeyDirectoryTestSupport do
  @moduledoc """
  Shared helpers of the suites of story `device-key-directory` (epic e2ee-client-support, REQ-2026-013): `POST /_matrix/client/v3/keys/claim`,
  `GET /_matrix/client/v3/keys/changes`, the E2E fields of `GET /sync` (`device_one_time_keys_count`, `device_unused_fallback_key_types`, `device_lists`) and the
  device-list change stream (table `device_list_changes`, migration 000060).

  Loaded once from `test_helper.exs` after the to-device helpers it builds on (users, devices, shared rooms, the sync client, statement counting, env seams). The FILE NAME
  ends with `oauth_test_support.exs` on purpose: `mix.exs` already ignores that suffix (`test_ignore_filters`), so no mix.exs edit is needed. Every function is `def`.

  ## The contract the suites pin (the story `## Decisions` D1-D20; the oracle context is the spec side)

    * Claim: `one_time_keys` `{user => {device => algorithm}}`; the answer `{"one_time_keys": ..., "failures": {}}`; a target that yields nothing is LEFT OUT; the numbers are in `limits/0`.
    * Stream: `device_list_changes (user_id, room_id, kind, pos)`, the latest change per user and room; `kind` `keys` (room `''`) / `join` / `leave`; `pos` is assigned at commit.
    * Token: `<core>.<account data pos>[.<to-device pos>][.d<device-list pos>]`; `dl_pos/1` reads the last group.
  """
  import ExUnit.Assertions

  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @claim "/_matrix/client/v3/keys/claim"
  @changes "/_matrix/client/v3/keys/changes"
  @upload "/_matrix/client/v3/keys/upload"
  @stream "device_list_changes"

  def claim_path, do: @claim
  def changes_path, do: @changes
  def stream_table, do: @stream

  @doc "The pinned numbers (story Decisions D5 and D8)."
  def limits do
    %{max_targets: 1000, user_per_min: 30, user_burst: 10, target_per_hour: 10, target_burst: 5, targets_per_min: 600, targets_burst: 1000}
  end

  # ── users, devices, worlds ──────────────────────────────────────────────────

  @doc "alice (the caller) and bob with two devices share a room; carol shares a room with bob only; dave shares nothing. Every device has a session (`%{uid, dev, at}`)."
  def world! do
    alice = TD.user!("DKA")
    bob1 = TD.user!("DKB")
    bob2 = TD.device!(bob1, "DKC")
    carol = TD.user!("DKK")
    dave = TD.user!("DKD")
    TD.share!(alice, bob1)
    TD.share!(bob1, carol)
    %{alice: alice, bob1: bob1, bob2: bob2, carol: carol, dave: dave}
  end

  @doc "A fresh peer (one device) that shares a room with `with_user`; returns the device map."
  def peer!(with_user, prefix \\ "DKP") do
    p = TD.user!(prefix)
    TD.share!(with_user, p)
    p
  end

  # ── key material (opaque to the server; the objects are compared verbatim) ──

  def key_obj(label), do: %{"key" => "key-#{label}", "signatures" => %{"@sig:test.local" => %{"ed25519:SIGDEV" => "sig-#{label}"}}}
  def fallback_obj(label), do: %{"key" => "fbk-#{label}", "fallback" => true, "signatures" => %{"@sig:test.local" => %{"ed25519:SIGDEV" => "fsig-#{label}"}}}

  @doc "`%{\"signed_curve25519:<id>\" => object}` for the ids (the object carries the id as its label)."
  def otks(ids, alg \\ "signed_curve25519"), do: Map.new(ids, fn id -> {"#{alg}:#{id}", key_obj(id)} end)

  def device_keys(%{uid: uid, dev: dev}, tag \\ "1") do
    %{
      "user_id" => uid,
      "device_id" => dev,
      "algorithms" => ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
      "keys" => %{"curve25519:#{dev}" => "curve-#{tag}-#{dev}", "ed25519:#{dev}" => "ed-#{tag}-#{dev}"},
      "signatures" => %{uid => %{"ed25519:#{dev}" => "devsig-#{tag}-#{dev}"}}
    }
  end

  # ── requests ────────────────────────────────────────────────────────────────

  def upload(device, body), do: TD.req(:post, @upload, device.at, body)

  def upload!(device, body) do
    c = upload(device, body)
    assert c.status == 200, "keys/upload: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    TD.json(c)
  end

  @doc """
  Publishes through the REAL route: the identity keys (`keys: tag`, default tag \"1\", `false` = none), one-time keys (`otks: [ids]`) and a fallback key (`fallback: id`).
  Returns `%{otks: %{\"<alg>:<id>\" => object}, fallback: {\"<alg>:<id>\", object} | nil}`.
  """
  def publish!(device, opts \\ []) do
    ids = Keyword.get(opts, :otks, [])
    fb = Keyword.get(opts, :fallback)
    keys = Keyword.get(opts, :keys, "1")
    otk_map = otks(ids)
    fb_map = if fb, do: %{"signed_curve25519:#{fb}" => fallback_obj(fb)}, else: %{}

    body =
      %{}
      |> then(&if(keys, do: Map.put(&1, "device_keys", device_keys(device, keys)), else: &1))
      |> then(&if(ids != [], do: Map.put(&1, "one_time_keys", otk_map), else: &1))
      |> then(&if(fb, do: Map.put(&1, "fallback_keys", fb_map), else: &1))

    upload!(device, body)
    %{otks: otk_map, fallback: if(fb, do: {"signed_curve25519:#{fb}", fb_map["signed_curve25519:#{fb}"]})}
  end

  @doc "`POST /keys/claim` of `caller` (a device map). `targets` is the `one_time_keys` map; `extra` is merged into the body."
  def claim(caller, targets, extra \\ %{}), do: TD.req(:post, @claim, caller.at, Map.merge(%{"one_time_keys" => targets}, extra))
  def claim_raw(caller, raw), do: TD.req(:post, @claim, caller.at, {:raw, raw})

  def claim!(caller, targets, extra \\ %{}) do
    c = claim(caller, targets, extra)
    assert c.status == 200, "keys/claim: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    body = TD.json(c)
    assert Map.keys(body) |> Enum.sort() == ["failures", "one_time_keys"], "the answer is exactly one_time_keys + failures: #{c.resp_body}"
    assert body["failures"] == %{}, "failures is always the empty object (the spec keys it by server name, Nebu has no federation)"
    body
  end

  @doc "The target map for one device: `%{uid => %{dev => alg}}`."
  def target(device_or_pair, alg \\ "signed_curve25519")
  def target(%{uid: uid, dev: dev}, alg), do: %{uid => %{dev => alg}}
  def target({uid, dev}, alg), do: %{uid => %{dev => alg}}
  def targets(list), do: TD.merge(Enum.map(list, &target/1))

  @doc "What the claim returned for one device: the `%{key id => object}` map or nil (left out)."
  def got(body, %{uid: uid, dev: dev}), do: got(body, uid, dev)
  def got(body, uid, dev), do: get_in(body, ["one_time_keys", uid, dev])

  @doc "Claims one key for one device and returns the `%{id => object}` map or nil."
  def claim_one!(caller, device, alg \\ "signed_curve25519"), do: got(claim!(caller, target(device, alg)), device)

  def changes(user, from, to) do
    q = [from: from, to: to] |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> URI.encode_query()
    TD.req(:get, @changes <> if(q == "", do: "", else: "?" <> q), user.at)
  end

  def changes_raw(user, query), do: TD.req(:get, @changes <> query, user.at)

  def changes!(user, from, to) do
    c = changes(user, from, to)
    assert c.status == 200, "keys/changes: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    body = TD.json(c)
    assert Enum.sort(Map.keys(body)) == ["changed", "left"], "exactly changed + left: #{c.resp_body}"
    assert is_list(body["changed"]) and is_list(body["left"]), "both are always lists: #{c.resp_body}"
    body
  end

  def sync(device, since \\ nil, params \\ []), do: TD.sync(device, since, params)

  @doc "A sync that returns the token to continue from (an initial sync when `since` is nil)."
  def token(device), do: TD.next(sync(device))

  def dl(body), do: body["device_lists"]
  def dl_changed(body), do: Enum.sort(get_in(body, ["device_lists", "changed"]) || [])
  def dl_left(body), do: Enum.sort(get_in(body, ["device_lists", "left"]) || [])

  @doc "The device-list position of a token (nil when the token has none)."
  def dl_pos(token) do
    case Regex.run(~r/\.d([0-9]+)\z/, token || "") do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  @doc "The token without its device-list group (what an old node or an old client holds)."
  def strip_dl(token), do: String.replace(token, ~r/\.d[0-9]+\z/, "")

  def ids(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()
  def ids(nil), do: nil

  # ── environment ─────────────────────────────────────────────────────────────

  @doc "The real limiter with a frozen clock (the claim buckets are node-local token buckets)."
  def enable_rate_limit, do: TD.enable_rate_limit()
  def set_clock(ms), do: TD.set_clock(ms)
  def clock, do: S.now()

  # ── database probes (runtime role) ──────────────────────────────────────────

  def unclaimed(uid, dev), do: T.sql!("SELECT count(*) FROM device_one_time_keys WHERE user_id = $1 AND device_id = $2 AND claimed_at IS NULL", [uid, dev]).rows |> hd() |> hd()
  def claimed(uid, dev), do: T.sql!("SELECT count(*) FROM device_one_time_keys WHERE user_id = $1 AND device_id = $2 AND claimed_at IS NOT NULL", [uid, dev]).rows |> hd() |> hd()
  def otk_total(uid, dev), do: T.sql!("SELECT count(*) FROM device_one_time_keys WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows |> hd() |> hd()

  @doc "`[key_id, used, key_id_text]` of the fallback row of (user, device, algorithm) or nil."
  def fallback_row(uid, dev, alg \\ "signed_curve25519") do
    case T.sql!("SELECT key_id, used FROM device_fallback_keys WHERE user_id = $1 AND device_id = $2 AND algorithm = $3", [uid, dev, alg]).rows do
      [row] -> row
      [] -> nil
    end
  end

  @doc "The stream rows of a user: `[[room_id, kind, pos]]` ordered by room."
  def stream_rows(uid), do: T.sql!("SELECT room_id, kind, pos FROM #{@stream} WHERE user_id = $1 ORDER BY room_id", [uid]).rows
  def stream_row(uid, room \\ ""), do: Enum.find(stream_rows(uid), fn [r, _k, _p] -> r == room end)
  def stream_pos(uid, room \\ ""), do: (case stream_row(uid, room) do [_, _, pos] -> pos; nil -> nil end)
  def stream_kind(uid, room \\ ""), do: (case stream_row(uid, room) do [_, kind, _] -> kind; nil -> nil end)
  def stream_count(uid), do: T.sql!("SELECT count(*) FROM #{@stream} WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  def current_position, do: elem(Nebu.Matrix.DeviceListStore.position(), 1)

  @doc "The latest position stamped for a user's key changes, or nil (no keys row)."
  def keys_pos(uid), do: stream_pos(uid, "")

  # ── logging ─────────────────────────────────────────────────────────────────

  def debug_log(fun), do: TD.debug_log(fun)

  # ── statements ──────────────────────────────────────────────────────────────

  @doc "`{result, statements}`: every statement (SQL text) the calling process issues while `fun` runs, begin / commit / noise excluded."
  def all_statements(fun) do
    # (apply/3: the module is loaded after this file by test_helper.exs; a literal call would warn at compile time, warnings are errors in the unit job)
    apply(Nebu.Matrix.MembershipStateTestSupport, :count_statements, [fun])
  end

  @doc "The statements that touch the key tables or the stream."
  def key_statements(statements), do: Enum.filter(statements, &Regex.match?(~r/device_one_time_keys|device_fallback_keys|device_list_changes/, &1))

  # ── holding a transaction (the commit order of the stream) ──────────────────

  @doc """
  Runs `fun` in a transaction of its own that stays OPEN (a writer that stamped early and commits late). Returns the handle for `finish/2`.
  MUST be called from the test process; an unfinished transaction is rolled back by `on_exit`.
  """
  def hold(fun), do: apply(Nebu.Compliance.UserDeletionTestSupport, :hold, [fun])
  def finish(handle, how), do: apply(Nebu.Compliance.UserDeletionTestSupport, :finish, [handle, how])

  # ── seeding for the GDPR erasure inventory ──────────────────────────────────

  @doc """
  Seeds the stream rows of `uid` through the REAL writers: its device keys (a `keys` row) and a room membership of `room` (a `join` row, by direct insert into
  `room_members`, the way the erasure seed writes its fake room). Returns `%{rows: n}`.
  """
  def seed_stream!(uid, dev, room) do
    :ok = Nebu.Matrix.DeviceKeyStore.put_device_keys(uid, dev, device_keys(%{uid: uid, dev: dev}, "seed"))
    T.sql!("INSERT INTO rooms (room_id, visibility, created_at) VALUES ($1, 'private', 1) ON CONFLICT DO NOTHING", [room])
    T.sql!("INSERT INTO room_members (room_id, user_id, joined_at) VALUES ($1, $2, 1) ON CONFLICT DO NOTHING", [room, uid])
    %{rows: stream_count(uid)}
  end
end
