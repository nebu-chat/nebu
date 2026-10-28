defmodule Nebu.Matrix.CrossSigningSignatureShapeTest do
  @moduledoc """
  Real-database tests for story `cross-signing-upload-races`, dev fix cycle 1 (code review MINOR-1, Kassandra F-1): `POST /keys/signatures/upload`
  validates the SHAPE of a submitted object's `signatures` before any store call.

  `signatures` must be a map (absent = empty map) whose every per-signer value is a map. Anything else (`null`, a string, a list, a per-signer value
  that is not a map) is a failure entry `M_INVALID_SIGNATURE` in a `200`, for a key id that matches no stored key AND for the key id of the stored
  master key, and nothing is written. It is never a crash: the store guards on maps, and a crash report would carry the call arguments (the key id,
  the submitted object) into the error log. The log check runs at :debug and leaves out only the existing per-request lines of
  `Nebu.Web.Plugs.RequestLogger` (they print the redacted body of every route; see `cross_signing_upload_races_test.exs`).

  async: false (committed rows, `Logger` level).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.CrossSigningKeyStore, as: Store
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @https "https://app.example.com/cb"

  setup do
    {:ok, E.setup_env!()}
  end

  defp world!(%{priv: priv, cid: cid}) do
    s = T.oauth_device!(cid, @https, priv, T.unique_sub(), "SH" <> String.upcase(T.rand(4)))
    keys = T.cross_signing_keys(s.user_id, "SHAPE")
    assert T.device_signing_upload(s.at, keys).status == 200, "precondition: the first upload"
    %{s: s, uid: s.user_id, master: Store.get_keys(s.user_id)["master_key"]}
  end

  defp key_id(obj), do: obj["keys"] |> Map.keys() |> hd() |> String.split(":", parts: 2) |> List.last()

  # the target object: the stored master key (a matching key id), or an object under a key id that matches no stored key
  defp target(w, :stored), do: w.master

  defp target(w, :unknown) do
    kid = "UNKNOWN" <> String.upcase(T.rand(8))
    %{"user_id" => w.uid, "usage" => ["master"], "keys" => %{"ed25519:" <> kid => kid}}
  end

  # the malformed `signatures` values; `marker` is a unique string that must never reach a log line
  defp bad(:null, _uid, _marker), do: nil
  defp bad(:string, _uid, marker), do: marker
  defp bad(:list, _uid, marker), do: [marker]
  defp bad(:per_signer_string, uid, marker), do: %{uid => marker}
  defp bad(:per_signer_list, uid, marker), do: %{uid => [marker]}
  defp bad(:second_signer_not_a_map, uid, marker), do: %{uid => %{"ed25519:SG" => "sig"}, "@other:test.local" => marker}

  defp capture_debug(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      ExUnit.CaptureLog.capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end

  # every captured entry except the per-request access / body lines of RequestLogger
  defp own_entries(log) do
    log
    |> String.split(~r/\n+(?=\d\d:\d\d:\d\d\.\d+ \[)/)
    |> Enum.reject(&(&1 =~ ~r/\A\d\d:\d\d:\d\d\.\d+ \[\w+\] (\[status: |\{"status":)/))
  end

  for shape <- [:null, :string, :list, :per_signer_string, :per_signer_list, :second_signer_not_a_map], kind <- [:unknown, :stored] do
    test "signatures #{shape}, #{kind} key id: a 200 with the failure entry, nothing stored, no key id or object in a log line", ctx do
      w = world!(ctx)
      obj = target(w, unquote(kind))
      kid = key_id(obj)
      marker = "shape-marker-" <> T.rand(10)
      submitted = Map.put(obj, "signatures", bad(unquote(shape), w.uid, marker))
      before = E.fp("cross_signing_keys", w.uid)

      log =
        capture_debug(fn ->
          result = T.safely(fn -> T.matrix_request(:post, "/_matrix/client/v3/keys/signatures/upload", w.s.at, body: %{w.uid => %{kid => submitted}}) end)
          send(self(), {:shape_result, result})
        end)

      assert_received {:shape_result, result}
      assert %Plug.Conn{status: 200} = conn = result, "the request must answer 200 with a failure entry, got #{inspect(result, limit: 5)}"
      assert T.json(conn)["failures"][w.uid][kid]["errcode"] == "M_INVALID_SIGNATURE"
      assert E.fp("cross_signing_keys", w.uid) == before, "nothing is written for a malformed signatures value"

      own = own_entries(log)
      refute Enum.any?(own, &(&1 =~ ~r/\A\d\d:\d\d:\d\d\.\d+ \[error\]/)), "no error log line (a crash report): #{inspect(own, limit: 3)}"
      checked = Enum.join(own, "\n")
      refute checked =~ kid, "the key id reached a log line"
      refute checked =~ marker, "the submitted object reached a log line"
    end
  end

  test "control: a well-formed signatures map on the stored key id is merged (the validation does not refuse valid input)", ctx do
    w = world!(ctx)
    sigs = %{w.uid => %{"ed25519:SGOK" => "sig-ok"}}

    conn = T.matrix_request(:post, "/_matrix/client/v3/keys/signatures/upload", w.s.at, body: %{w.uid => %{key_id(w.master) => Map.put(w.master, "signatures", sigs)}})

    assert conn.status == 200 and T.json(conn) == %{"failures" => %{}}
    assert Store.get_keys(w.uid)["master_key"]["signatures"] == sigs
  end

  test "control: an object without a signatures key is a valid empty merge (absent = empty map)", ctx do
    w = world!(ctx)
    conn = T.matrix_request(:post, "/_matrix/client/v3/keys/signatures/upload", w.s.at, body: %{w.uid => %{key_id(w.master) => Map.delete(w.master, "signatures")}})
    assert conn.status == 200 and T.json(conn) == %{"failures" => %{}}
  end

  # ─── fix cycle 2 (Kassandra D-1): MALFORMED STORED signatures ────────────────────────────────────────────────────────────────────────
  #
  # The key uploads do not validate the shape of the `signatures` inside a key object (no API change in this story), so a user can STORE a
  # cross-signing key or a device key whose `signatures` is "x" or `{"@me": "x"}`. A later well-shaped signatures/upload with the matching object
  # must merge cleanly (the malformed stored part counts as no signatures and is dropped) and never crash: a crash report would print the
  # submitted signer key ids and signatures (D5).

  defp malformed(:string, _uid, marker), do: marker
  defp malformed(:per_signer_string, uid, marker), do: %{uid => marker}

  defp session!(%{priv: priv, cid: cid}) do
    dev = "SM" <> String.upcase(T.rand(4))
    s = T.oauth_device!(cid, @https, priv, T.unique_sub(), dev)
    {s, dev}
  end

  defp upload_signatures(at, body), do: T.safely(fn -> T.matrix_request(:post, "/_matrix/client/v3/keys/signatures/upload", at, body: body) end)

  defp request_logged(fun) do
    log =
      capture_debug(fn ->
        send(self(), {:stored_shape_result, fun.()})
      end)

    assert_received {:stored_shape_result, result}
    {result, log}
  end

  defp refute_logged!(log, material) do
    own = own_entries(log)
    refute Enum.any?(own, &(&1 =~ ~r/\A\d\d:\d\d:\d\d\.\d+ \[error\]/)), "no error log line (a crash report): #{inspect(own, limit: 3)}"
    checked = Enum.join(own, "\n")
    for m <- material, do: refute(checked =~ m, "submitted or stored material reached a log line: #{String.slice(m, 0, 12)}")
  end

  for body_key <- ["master_key", "self_signing_key"], stored <- [:string, :per_signer_string] do
    test "stored #{body_key} with signatures #{stored}: a matching signatures/upload merges cleanly, 200, no crash, nothing in a log line", ctx do
      {s, _dev} = session!(ctx)
      uid = s.user_id
      marker = "stored-marker-" <> T.rand(10)
      keys = T.cross_signing_keys(uid, "MAL")
      keys = Map.update!(keys, unquote(body_key), &Map.put(&1, "signatures", malformed(unquote(stored), uid, marker)))
      assert T.device_signing_upload(s.at, keys).status == 200, "precondition: the first upload stores the malformed signatures as they are"
      stored_obj = Store.get_keys(uid)[unquote(body_key)]
      assert stored_obj["signatures"] == malformed(unquote(stored), uid, marker), "precondition: the malformed value is stored"

      kid = key_id(stored_obj)
      sig_value = "sig-ok-" <> T.rand(10)
      sigs = %{uid => %{"ed25519:SGOK" => sig_value}}

      {result, log} = request_logged(fn -> upload_signatures(s.at, %{uid => %{kid => Map.put(stored_obj, "signatures", sigs)}}) end)

      assert %Plug.Conn{status: 200} = conn = result, "the request must answer 200, got #{inspect(result, limit: 5)}"
      assert T.json(conn) == %{"failures" => %{}}
      assert Store.get_keys(uid)[unquote(body_key)]["signatures"] == sigs, "the malformed stored part is dropped, the new signature is merged"
      refute_logged!(log, [kid, marker, sig_value])
    end
  end

  for stored <- [:string, :per_signer_string] do
    test "stored device key with signatures #{stored}: a matching signatures/upload merges cleanly, 200, no crash, nothing in a log line", ctx do
      {s, dev} = session!(ctx)
      uid = s.user_id
      marker = "stored-marker-" <> T.rand(10)

      device_keys = %{
        "user_id" => uid,
        "device_id" => dev,
        "algorithms" => ["m.olm.v1.curve25519-aes-sha2"],
        "keys" => %{"ed25519:#{dev}" => "ed-" <> dev, "curve25519:#{dev}" => "cu-" <> dev},
        "signatures" => malformed(unquote(stored), uid, marker)
      }

      assert T.matrix_request(:post, "/_matrix/client/v3/keys/upload", s.at, body: %{"device_keys" => device_keys}).status == 200
      stored_obj = Nebu.Matrix.DeviceKeyStore.query_devices([uid])[uid][dev]
      assert stored_obj["signatures"] == malformed(unquote(stored), uid, marker), "precondition: the device key upload stores the malformed signatures"

      sig_value = "sig-ok-" <> T.rand(10)
      sigs = %{uid => %{"ed25519:SGOK" => sig_value}}
      submitted = stored_obj |> Map.delete("unsigned") |> Map.put("signatures", sigs)

      {result, log} = request_logged(fn -> upload_signatures(s.at, %{uid => %{dev => submitted}}) end)

      assert %Plug.Conn{status: 200} = conn = result, "the request must answer 200, got #{inspect(result, limit: 5)}"
      assert T.json(conn) == %{"failures" => %{}}
      assert Nebu.Matrix.DeviceKeyStore.query_devices([uid])[uid][dev]["signatures"] == sigs, "the malformed stored part is dropped, the new signature is merged"
      refute_logged!(log, [marker, sig_value, "ed-" <> dev])
    end
  end
end
