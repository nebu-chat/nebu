defmodule Nebu.Matrix.EventSizeTest do
  @moduledoc """
  Story `event-size-limit` (epic oauth-broker, follow-up `ep`), AC1: the pure accounting of `Nebu.Matrix.EventSize`.

  The size of an event is `byte_size(CanonicalJson.encode!(stored_event))`, where `stored_event` is the six signed keys (`content`,
  `origin_server_ts`, `room_id`, `sender`, `state_key` (the string, or JSON `null` for a message event), `type`) plus `event_id` and
  `signatures` (D1). The module under test is pure (no DB), so this suite is `async: true` and has no `:integration` tag.

  Every EXPECTED size is computed by this test itself, independently of `EventSize` (AC1 (d)): the test builds the stored map EXACTLY like
  `EventDispatcher.Server.emit_state_event_at/6` does (the real `EventId.generate/1`, a real Ed25519 signature of the canonical bytes with a test key) and
  encodes it. A pre-check that is off by the length of the event id or by `"state_key":null` can therefore not pass by comparing the code with itself.

  Pinned API of the module (decided here, the story names the functions and their arities; the return shapes are the ATDD step's decision):

    * `max_event_bytes/0` -> `65_536`, `max_key_bytes/0` -> `255`, `signed_overhead/0` -> `171`
    * `stored_bytes(event_json)` -> `byte_size(event_json) + signed_overhead()` (the bytes of the SIGNED canonical JSON the write sites hold)
    * `predicted_bytes(envelope, content_bytes)`: `envelope` is the STRING-keyed event map WITHOUT `"content"` (`"room_id"`, `"type"`,
      `"state_key"` (`nil` for a message event), `"sender"`, `"origin_server_ts"`), `content_bytes` the `byte_size(Jason.encode!(content))`
    * `check_keys(type, state_key, sender)` -> `:ok | {:error, :type_too_long | :state_key_too_long | :sender_too_long}`; a `nil` state key (the
      `/send` route) is accepted and not counted
    * `check(envelope, content_bytes)` -> `:ok | {:error, :event_too_large}` (the size only; the keys are `check_keys/3`)

  The functions are called through `apply/3` with a variable function name, so that a not-yet-existing module fails the TESTS (UndefinedFunctionError),
  never the compile of the whole run (`--warnings-as-errors`).
  """
  use ExUnit.Case, async: true

  alias Nebu.Matrix.CanonicalJson
  alias Nebu.Matrix.EventId

  @es Nebu.Matrix.EventSize

  defp es(fun, args), do: apply(@es, fun, args)

  # a signing key of this test (the production key is {_pub, priv} in :persistent_term)
  defp priv do
    {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519, :binary.copy("s", 32))
    priv
  end

  # the stored map, built exactly like emit_state_event_at/6 / do_send_event/7 (D1)
  defp stored(event_map) do
    event_id = EventId.generate(event_map)
    sig = :crypto.sign(:eddsa, :none, CanonicalJson.encode!(event_map), [priv(), :ed25519])

    event_map
    |> Map.put("event_id", event_id)
    |> Map.put("signatures", %{"nebu" => Base.encode64(sig)})
  end

  # the INDEPENDENT expected size of the event
  defp real_size(event_map), do: event_map |> stored() |> CanonicalJson.encode!() |> byte_size()

  defp envelope(room, sender, type, state_key, ts),
    do: %{"room_id" => room, "type" => type, "state_key" => state_key, "sender" => sender, "origin_server_ts" => ts}

  defp event_map(envelope, content), do: Map.put(envelope, "content", content)

  # ─── generators (seeded: a failure is reproducible) ───────────────────────────────

  @pool ["a", "Z", "0", " ", "\"", "\\", "/", "\u007f", "\u2028", "\u2029", "é", "€", "😀", "\u0000", "\u0001", "\u001f", "\b", "\t", "\n", "\f", "\r", "<", "&"]

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  defp gen_string do
    for(_ <- 1..:rand.uniform(18), into: "", do: pick(@pool))
  end

  defp gen_value(depth) do
    kinds = if depth <= 0, do: 7, else: 9

    case :rand.uniform(kinds) do
      1 -> :rand.uniform(1_000_000_000_000_000) - 500_000_000_000_000
      2 -> :rand.uniform() * 1000 - 500
      3 -> pick([true, false, nil])
      4 -> gen_string()
      5 -> 0
      6 -> %{}
      7 -> pick([1.0e22, 100.0, 0.1, 9_007_199_254_740_991, -9_007_199_254_740_991])
      8 -> for(_ <- 1..:rand.uniform(4), do: gen_value(depth - 1))
      9 -> gen_map(depth - 1, :rand.uniform(6) - 1)
    end
  end

  defp gen_map(depth, keys), do: for(_ <- 1..keys//1, into: %{}, do: {gen_string(), gen_value(depth)})

  # a content: string keys, nested maps, lists, a top-level map with MORE than 32 keys now and then (Erlang maps stop preserving order there)
  defp gen_content(i) do
    base = gen_map(3, :rand.uniform(8) - 1)
    if rem(i, 5) == 0, do: Map.merge(base, for(n <- 1..40, into: %{}, do: {"k#{n}-#{gen_string()}", gen_value(2)})), else: base
  end

  defp gen_state_key(i) do
    case rem(i, 5) do
      0 -> nil
      1 -> ""
      2 -> "@" <> String.duplicate("u", 100) <> ":test.local"
      3 -> "!child:test.local"
      4 -> gen_string()
    end
  end

  @servers ["test.local", "a-rather-long-server-name.chat.example.org"]

  # ═══ AC1 (a), (b), (c), (d) ═══════════════════════════════════════════════════════════════

  describe "AC1 (a) - accounting equals the stored size" do
    test "signed_overhead/0 is 171: ,\"event_id\":\"$<43>\" is 58 bytes and ,\"signatures\":{\"nebu\":\"<88>\"} is 113" do
      assert es(:signed_overhead, []) == 171
      assert es(:max_event_bytes, []) == 65_536
      assert es(:max_key_bytes, []) == 255

      # an independent derivation: the stored map minus the two keys is the signed map
      m = envelope("!r:test.local", "@a:test.local", "m.room.topic", "", 1_700_000_000_000) |> event_map(%{})
      assert real_size(m) - byte_size(CanonicalJson.encode!(m)) == 171
    end

    test "stored_bytes/1 adds exactly the overhead to the signed canonical bytes it is given" do
      assert es(:stored_bytes, ["{}"]) == 2 + 171
      assert es(:stored_bytes, [String.duplicate("a", 1000)]) == 1171
      assert es(:stored_bytes, [""]) == 171
    end

    test "200 generated events (maps above 32 keys, lists, 1-4 byte UTF-8, escapes, C0, DEL, U+2028, numbers, null, 5 state keys): stored_bytes equals the re-encoded stored map" do
      :rand.seed(:exsss, {11, 22, 33})

      for i <- 1..200 do
        server = Enum.at(@servers, rem(i, 2))
        room = "!" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> ":" <> server
        env = envelope(room, "@sender#{i}:" <> server, pick(["m.room.topic", "m.space.child", "org.example.custom_event"]), gen_state_key(i), 1_700_000_000_000 + i)
        content = gen_content(i)
        map = event_map(env, content)

        expected = real_size(map)
        assert es(:stored_bytes, [CanonicalJson.encode!(map)]) == expected, "case #{i}: #{inspect(map, limit: 5, printable_limit: 80)}"
      end
    end

    test "the same 200 events: byte_size(Jason.encode!(content)) == byte_size(CanonicalJson.encode!(content)) (only the key ORDER differs)" do
      :rand.seed(:exsss, {44, 55, 66})

      for i <- 1..200 do
        content = gen_content(i)
        assert byte_size(Jason.encode!(content)) == byte_size(CanonicalJson.encode!(content)), "case #{i}"
      end
    end

    test "the same 200 events: predicted_bytes(envelope, byte_size(Jason.encode!(content))) equals the real stored size (AC1 (c))" do
      :rand.seed(:exsss, {77, 88, 99})

      for i <- 1..200 do
        server = Enum.at(@servers, rem(i, 2))
        room = "!" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> ":" <> server
        env = envelope(room, "@sender#{i}:" <> server, pick(["m.room.topic", "m.room.message", "org.example.custom_event"]), gen_state_key(i), 1_700_000_000_000 + i)
        content = gen_content(i)

        assert es(:predicted_bytes, [env, byte_size(Jason.encode!(content))]) == real_size(event_map(env, content)), "case #{i}"
      end
    end

    test "a message event carries \"state_key\": null in the signed bytes: the envelope with nil costs the 4 bytes of null, not the 2 of an empty string" do
      env = envelope("!r:test.local", "@a:test.local", "m.room.message", nil, 1_700_000_000_000)
      content = %{"msgtype" => "m.text", "body" => "hello"}

      with_null = real_size(event_map(env, content))
      with_empty = real_size(event_map(%{env | "state_key" => ""}, content))
      assert with_null == with_empty + 2

      assert es(:predicted_bytes, [env, byte_size(Jason.encode!(content))]) == with_null
      assert es(:predicted_bytes, [%{env | "state_key" => ""}, byte_size(Jason.encode!(content))]) == with_empty
    end
  end

  # ═══ AC1 (e): the limits, in BYTES ═══════════════════════════════════════════════════════

  describe "AC1 (e) - limits" do
    @room "!0123456789abcdef:test.local"
    @sender "@alice:test.local"
    @ts 1_700_000_000_000

    # a content with an ASCII "pad" so that the stored event is exactly `target` bytes (computed by this test, independently)
    defp sized_content(env, target) do
      base = real_size(event_map(env, %{"pad" => ""}))
      assert target >= base
      %{"pad" => String.duplicate("a", target - base)}
    end

    test "a stored size of exactly 65 536 bytes is ok, 65 537 is {:error, :event_too_large}, for a state event and for a message event (null state key)" do
      for state_key <- ["", "!child:test.local", nil] do
        env = envelope(@room, @sender, if(state_key == nil, do: "m.room.message", else: "m.space.child"), state_key, @ts)

        exact = sized_content(env, 65_536)
        assert real_size(event_map(env, exact)) == 65_536
        assert es(:check, [env, byte_size(Jason.encode!(exact))]) == :ok, "65 536 for state key #{inspect(state_key)}"

        one_more = sized_content(env, 65_537)
        assert real_size(event_map(env, one_more)) == 65_537
        assert es(:check, [env, byte_size(Jason.encode!(one_more))]) == {:error, :event_too_large}, "65 537 for state key #{inspect(state_key)}"

        one_less = sized_content(env, 65_535)
        assert es(:check, [env, byte_size(Jason.encode!(one_less))]) == :ok
      end
    end

    test "a tiny event is ok" do
      env = envelope(@room, @sender, "m.room.topic", "", @ts)
      assert es(:check, [env, byte_size(Jason.encode!(%{"topic" => "hi"}))]) == :ok
    end

    test "type and state_key of exactly 255 bytes are ok, 256 are too long; sender likewise" do
      a255 = String.duplicate("a", 255)
      a256 = String.duplicate("a", 256)

      assert es(:check_keys, [a255, "", @sender]) == :ok
      assert es(:check_keys, ["m.room.topic", a255, @sender]) == :ok
      assert es(:check_keys, [a255, a255, @sender]) == :ok
      assert es(:check_keys, [a256, "", @sender]) == {:error, :type_too_long}
      assert es(:check_keys, ["m.room.topic", a256, @sender]) == {:error, :state_key_too_long}
      assert es(:check_keys, ["m.room.topic", "", "@" <> String.duplicate("u", 252) <> ":x"]) == :ok, "a sender of exactly 255 bytes"
      assert es(:check_keys, ["m.room.topic", "", "@" <> String.duplicate("u", 253) <> ":x"]) == {:error, :sender_too_long}, "256 bytes"
    end

    test "a nil state key (the /send route) is accepted and not counted" do
      assert es(:check_keys, [String.duplicate("t", 255), nil, @sender]) == :ok
      assert es(:check_keys, [String.duplicate("t", 256), nil, @sender]) == {:error, :type_too_long}
    end

    test "keys are counted in BYTES: 85 x euro (255) ok, 86 x euro (258) too long, 128 x e-acute (256) too long, 63 x emoji + abc (255) ok" do
      euro85 = String.duplicate("€", 85)
      euro86 = String.duplicate("€", 86)
      eacute128 = String.duplicate("é", 128)
      emoji = String.duplicate("😀", 63) <> "abc"

      assert byte_size(euro85) == 255 and byte_size(euro86) == 258 and byte_size(eacute128) == 256 and byte_size(emoji) == 255

      for {value, verdict} <- [{euro85, :ok}, {euro86, :too_long}, {eacute128, :too_long}, {emoji, :ok}] do
        assert es(:check_keys, [value, "", @sender]) == expect_keys(verdict, :type_too_long), "type #{byte_size(value)} bytes"
        assert es(:check_keys, ["m.room.topic", value, @sender]) == expect_keys(verdict, :state_key_too_long), "state_key #{byte_size(value)} bytes"
      end
    end

    defp expect_keys(:ok, _), do: :ok
    defp expect_keys(:too_long, error), do: {:error, error}

    test "a type with quotes counts ONE byte per quote (the raw string bytes, not its JSON form where a quote is two)" do
      assert es(:check_keys, [String.duplicate("\"", 255), "", @sender]) == :ok
      assert es(:check_keys, [String.duplicate("\"", 256), "", @sender]) == {:error, :type_too_long}
      assert es(:check_keys, ["m.room.topic", String.duplicate("\\", 255), @sender]) == :ok
      assert es(:check_keys, ["m.room.topic", String.duplicate("\\", 256), @sender]) == {:error, :state_key_too_long}
    end
  end

  # ═══ AC1 (f): escapes and numbers ════════════════════════════════════════════════════════

  describe "AC1 (f) - escapes and numbers (pins of today's canonical rendering; follow-up fn)" do
    test "10 000 x U+0001 is 60 002 canonical bytes (6 per character + the quotes), 10 000 x e-acute 20 002, 10 000 x / 10 002" do
      assert byte_size(CanonicalJson.encode!(String.duplicate("\u0001", 10_000))) == 60_002
      assert byte_size(CanonicalJson.encode!(String.duplicate("é", 10_000))) == 20_002
      assert byte_size(CanonicalJson.encode!(String.duplicate("/", 10_000))) == 10_002
      # and the accounting sees exactly these bytes
      env = envelope("!r:test.local", "@a:test.local", "m.room.topic", "", 1_700_000_000_000)
      for c <- ["\u0001", "é", "/"] do
        content = %{"pad" => String.duplicate(c, 10_000)}
        assert es(:predicted_bytes, [env, byte_size(Jason.encode!(content))]) == real_size(event_map(env, content))
      end
    end

    test "a decoded float 100.0 costs 5 bytes (1e2 in the body is 3): the canonical form grows" do
      assert Jason.decode!("1e2") == 100.0
      assert byte_size(CanonicalJson.encode!(Jason.decode!("1e2"))) == 5
      assert byte_size(CanonicalJson.encode!(Jason.decode!("[1e2,1e2]"))) == 2 + 5 + 1 + 5
    end

    test "-0 decodes to the integer 0 (1 byte), 1.0 stays the float 1.0 (3 bytes), -0.0 renders as -0.0 (4 bytes): the pins of fn" do
      assert Jason.decode!("-0") == 0
      assert byte_size(CanonicalJson.encode!(Jason.decode!("-0"))) == 1
      assert Jason.decode!("1.0") == 1.0
      assert byte_size(CanonicalJson.encode!(Jason.decode!("1.0"))) == 3
      assert byte_size(CanonicalJson.encode!(Jason.decode!("-0.0"))) == 4
    end
  end
end
