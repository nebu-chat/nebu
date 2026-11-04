defmodule Nebu.Matrix.HttpKeyDirectory do
  @moduledoc """
  HTTP side of `POST /_matrix/client/v3/keys/claim` and `GET /_matrix/client/v3/keys/changes` (story device-key-directory, epic e2ee-client-support,
  REQ-2026-013). The routes live in `Nebu.Web.Router.Protected` (authentication first); the stores are `Nebu.Matrix.KeyClaimStore` and
  `Nebu.Matrix.DeviceListStore`. Key material is never logged (law: no sensitive data in logs).

  ## Claim

    * `400 M_NOT_JSON` malformed JSON; `400 M_BAD_JSON` `one_time_keys` missing / not an object, an entry that is not an object, an algorithm that is not a string;
      `400 M_INVALID_PARAM` more than 1000 targets (before any bucket is charged);
    * `429 M_LIMIT_EXCEEDED` a rate bucket of the request is empty (all buckets are checked all-or-nothing BEFORE the consuming statement);
    * `200 {"one_time_keys": ..., "failures": {}}`: every target that yielded no key (unknown, keyless, not shared, remote, malformed id) is LEFT OUT, `failures` is
      always empty (the spec keys it by server name, Nebu has no federation).

  The buckets (node-local like every rate tier: N x the limit in a cluster): per caller 30 / min, burst 10 (counts requests); per caller 600 / min, burst 1000
  (counts the syntactically valid targets of a request; a cost above the burst is charged as the burst); per (caller, target user, target
  device) 10 / hour, burst 5, charged for EVERY syntactically valid target whatever its state (a 429 that depends on the target would be an existence oracle).
  The per-target key is `{"keys_claim_target", caller, sha256(user_id <> 0 <> device_id)}` (fixed size, never a term of the request body: an ETS key that is a
  sub-binary would pin the whole body). The charge has two stages because a denied multi-bucket charge still inserts the rows of the buckets that did not deny:
  first the two caller buckets, and only when they pay the per-target buckets (a request denied in stage 1 creates no per-target row; a stage 2 denial keeps
  the stage 1 tokens, the cost never depends on the state of a target).

  ## Changes

  `from` and `to` are sync tokens: `400 M_MISSING_PARAM` when one is missing or empty, `400 M_INVALID_PARAM` when one is malformed. A well-formed token without a
  device-list position ("expired") answers conservatively (every shared user is `changed`).
  """
  import Nebu.Matrix.Http, only: [send_json: 3, error: 4]
  require Logger

  alias Nebu.Matrix.{DeviceListStore, KeyClaimStore}

  @max_targets 1000
  @max_id_bytes 255
  @user_per_min 30
  @user_burst 10
  @target_per_min 10 / 60
  @target_burst 5
  @targets_per_min 600
  @targets_burst 1000

  @doc "The pinned limits (the tests and the docs read these numbers)."
  def limits, do: %{max_targets: @max_targets, user_per_min: @user_per_min, user_burst: @user_burst, target_per_hour: 10, target_burst: @target_burst, targets_per_min: @targets_per_min, targets_burst: @targets_burst}

  @spec claim(Plug.Conn.t()) :: Plug.Conn.t()
  def claim(conn) do
    user = conn.assigns[:current_user]

    with :ok <- check_json(conn),
         {:ok, targets} <- targets(conn.body_params),
         :ok <- check_cap(targets),
         valid = Enum.filter(targets, &valid_target?/1),
         :ok <- charge(user, valid) do
      case KeyClaimStore.claim(user, valid) do
        {:ok, keys} ->
          send_json(conn, 200, %{"one_time_keys" => keys, "failures" => %{}})

        {:error, reason} ->
          Logger.error("keys/claim: the claim failed (#{error_kind(reason)})")
          error(conn, 500, "M_UNKNOWN", "Internal error")
      end
    else
      {:error, {:limited, seconds}} -> Nebu.Web.Plugs.RateLimit.respond_limited(conn, seconds)
      {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
    end
  end

  @spec changes(Plug.Conn.t()) :: Plug.Conn.t()
  def changes(conn) do
    user = conn.assigns[:current_user]
    q = conn.query_params

    with {:ok, from} <- token(q["from"], "from"),
         {:ok, to} <- token(q["to"], "to") do
      case DeviceListStore.changes(user, from, if(from == nil, do: nil, else: to)) do
        {:ok, %{changed: changed, left: left}} ->
          send_json(conn, 200, %{"changed" => changed, "left" => left})

        {:error, reason} ->
          Logger.error("keys/changes: the read failed (#{error_kind(reason)})")
          error(conn, 500, "M_UNKNOWN", "Internal error")
      end
    else
      {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
    end
  end

  defp token(nil, name), do: {:error, {400, "M_MISSING_PARAM", "Missing query parameter `#{name}`"}}
  defp token("", name), do: {:error, {400, "M_MISSING_PARAM", "Missing query parameter `#{name}`"}}

  defp token(value, name) do
    case DeviceListStore.parse_token(value) do
      {:ok, pos} -> {:ok, pos}
      :error -> {:error, {400, "M_INVALID_PARAM", "Invalid sync token in `#{name}`"}}
    end
  end

  defp check_json(conn) do
    if conn.assigns[:json_parse_error] == true, do: {:error, {400, "M_NOT_JSON", "Request body is not valid JSON"}}, else: :ok
  end

  # `[{user_id, device_id, algorithm}]`; the structure is validated (a 400), the ids are not (an unreachable target is left out silently)
  defp targets(%{"one_time_keys" => keys}) when is_map(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn
      {uid, devices}, {:ok, acc} when is_map(devices) ->
        case Enum.reduce_while(devices, {:ok, acc}, fn
               {did, alg}, {:ok, inner} when is_binary(alg) -> {:cont, {:ok, [{uid, did, alg} | inner]}}
               _, _ -> {:halt, :error}
             end) do
          {:ok, inner} -> {:cont, {:ok, inner}}
          :error -> {:halt, bad_json()}
        end

      _, _ ->
        {:halt, bad_json()}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp targets(_), do: bad_json()

  defp bad_json, do: {:error, {400, "M_BAD_JSON", "Request body must be a JSON object with an object member `one_time_keys` of {user: {device: algorithm}}"}}

  defp check_cap(targets) do
    if length(targets) > @max_targets, do: {:error, {400, "M_INVALID_PARAM", "Too many targets (at most #{@max_targets})"}}, else: :ok
  end

  defp valid_target?({uid, did, alg}) do
    ok? = fn s -> String.valid?(s) and byte_size(s) in 1..@max_id_bytes and not String.contains?(s, <<0>>) end
    ok?.(uid) and ok?.(did) and ok?.(alg) and String.starts_with?(uid, "@") and String.contains?(uid, ":")
  end

  # Two stages (see the moduledoc): `take_all/1` evaluates every bucket and keeps the rows it inserted even when another bucket denies, so the
  # per-target rows (up to 1000 per request) are only touched once the caller buckets have paid.
  defp charge(user, valid) do
    caller =
      [{{"keys_claim", user}, 1, @user_per_min, @user_burst}] ++
        if(valid == [], do: [], else: [{{"keys_claim_targets", user}, length(valid), @targets_per_min, @targets_burst}])

    with :ok <- take_all(caller),
         do: take_all(for({uid, did, _alg} <- valid, do: {target_key(user, uid, did), 1, @target_per_min, @target_burst}))
  end

  defp take_all(buckets) do
    case Nebu.Web.Plugs.RateLimit.take_all(buckets) do
      :ok -> :ok
      {:deny, seconds} -> {:error, {:limited, seconds}}
    end
  end

  # fixed size and independent of the request body (`:crypto.hash/2` returns a fresh 32 byte heap binary)
  defp target_key(user, uid, did), do: {"keys_claim_target", user, :crypto.hash(:sha256, [uid, 0, did])}

  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "error"
end
