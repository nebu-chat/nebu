defmodule Nebu.Matrix.UserIdLengthTest do
  @moduledoc """
  Story `event-size-limit` (epic oauth-broker, follow-up `ep`), AC11 (a), (b), decision D12 (Oracle gate): a Matrix user id is at most 255 BYTES
  (appendix "Identifier length limits"), bounded at its ONE source, `Nebu.Matrix.UserId.from_claims/2`.

  Premise (verified in the story): the localpart of an id comes from an IdP claim and `sanitize/1` has NO length bound, so a 300-character claim yielded a
  300+-byte user id, which then travels as `sender` / `state_key` of member events. D12:

    * an id of at most 254 bytes is unchanged, byte for byte (no identity change for anyone with a normal claim);
    * otherwise (255 bytes or more) the localpart becomes its first `255 - 2 - byte_size(server_name) - 17` bytes, `"-"`, and the first 16 lowercase hex
      characters of the SHA-256 of the FULL sanitised localpart, so the hashed id is EXACTLY 255 bytes (deterministic: login, `OidcPlug`, SSO, account
      management and the Admin agree; two long claims with a common prefix get different ids; grammar-valid, ASCII);
    * `UserId.valid?/1` gains the same 255-byte bound; `UserId.valid_shape?/1` is the grammar WITHOUT the bound (removal / teardown of a stored legacy id).

  CODE REVIEW CYCLE 1 (Kassandra #1, MEDIUM) CHANGED THE CONTRACT DELIBERATELY (recorded in the story Change Log; not a weakening): the pass-through bound is
  254 bytes, not 255, so that the natural ids (at most 254 bytes) and the hashed ids (exactly 255 bytes) are disjoint BY LENGTH: no claim a user can choose
  collides with the hashed id of another user's long claim. The hash-only branch is gone: a server name that leaves fewer than 18 bytes of the localpart is a
  configuration error and the node refuses to boot (`Nebu.Application.check_server_name_length!/1`, tested in `application_test.exs`).

  `async: false` (the story says `async: true`): the configured claim is read through the global `:matrix, :oidc_claim_reader` seam and the
  `OidcClaimCache` (`persistent_term`), exactly as `user_id_name_claim_test.exs` does; a concurrent suite would see this suite's claim.

  The boot refusal for a server name that leaves fewer than 18 bytes for the localpart is tested in `application_test.exs`; the predicate behind it
  (`UserId.server_name_leaves_room?/1`) has its boundary tests here (235 / 236 bytes).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.UserId

  @server "test.local"
  @long_server "a-fairly-long-server-name.chat.example.org"

  setup do
    prior = Application.fetch_env(:matrix, :oidc_claim_reader)
    Application.put_env(:matrix, :oidc_claim_reader, fn -> nil end)
    Nebu.Matrix.OidcClaimCache.reset_for_test()

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:matrix, :oidc_claim_reader, v)
        :error -> Application.delete_env(:matrix, :oidc_claim_reader)
      end

      Nebu.Matrix.OidcClaimCache.reset_for_test()
    end)

    :ok
  end

  defp configure_claim(claim) do
    Application.put_env(:matrix, :oidc_claim_reader, fn -> claim end)
    Nebu.Matrix.OidcClaimCache.reset_for_test()
  end

  # the id D12 prescribes for a sanitised localpart that does not fit (computed by this test, independently of the code)
  defp hashed_id(full_localpart, server) do
    keep = 255 - 2 - byte_size(server) - 17
    hex = :crypto.hash(:sha256, full_localpart) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "@" <> binary_part(full_localpart, 0, keep) <> "-" <> hex <> ":" <> server
  end

  # a localpart so that "@" <> lp <> ":" <> server is exactly `total` bytes
  defp localpart_for(total, server), do: String.duplicate("a", total - 2 - byte_size(server))

  describe "AC11 (a) - from_claims/2 bounds the id to 255 bytes" do
    test "a claim giving exactly 254 bytes is unchanged, byte for byte" do
      lp = localpart_for(254, @server)
      id = UserId.from_claims(%{"sub" => "s1", "preferred_username" => lp}, @server)

      assert id == "@" <> lp <> ":" <> @server
      assert byte_size(id) == 254
      assert UserId.valid?(id)
    end

    test "a claim giving exactly 255 bytes is HASHED (domain separation by length: natural ids are at most 254 bytes, hashed ids exactly 255)" do
      lp = localpart_for(255, @server)
      id = UserId.from_claims(%{"sub" => "s1", "preferred_username" => lp}, @server)

      refute id == "@" <> lp <> ":" <> @server
      assert id == hashed_id(lp, @server)
      assert byte_size(id) == 255
      assert UserId.valid?(id)
    end

    test "no short claim can produce the hashed id of a long claim: every natural id is shorter than 255 bytes, every hashed id is exactly 255" do
      long = String.duplicate("v", 400)
      victim = UserId.from_claims(%{"sub" => long}, @server)
      assert byte_size(victim) == 255

      # the attacker picks the localpart of the victim's id as his own claim: that id is 255 bytes long, so it is hashed, and differs from the victim's
      attacker_lp = victim |> String.trim_leading("@") |> String.replace_suffix(":" <> @server, "")
      attacker = UserId.from_claims(%{"sub" => attacker_lp}, @server)
      refute attacker == victim
      assert byte_size(attacker) == 255

      for n <- [20, 100, 200, 250, 253, 254, 255, 256, 300] do
        id = UserId.from_claims(%{"sub" => localpart_for(n, @server)}, @server)
        if n <= 254, do: assert(byte_size(id) == n, "natural id of #{n} bytes"), else: assert(byte_size(id) == 255, "hashed id of a claim giving #{n} bytes")
      end
    end

    test "a claim giving 256 bytes becomes exactly D12's form: first 236 - byte_size(server) bytes, a dash and 16 hex of SHA-256 of the full sanitised localpart" do
      lp = localpart_for(256, @server)
      id = UserId.from_claims(%{"sub" => "s1", "preferred_username" => lp}, @server)

      assert id == hashed_id(lp, @server)
      assert byte_size(id) == 255
      assert UserId.valid?(id), "grammar-valid, ASCII"
      assert String.ends_with?(id, ":" <> @server)
    end

    test "a 1 000-character claim becomes D12's form (255 bytes), valid, for a short and for a long server name" do
      lp = String.duplicate("x", 1_000)

      for server <- [@server, @long_server] do
        id = UserId.from_claims(%{"sub" => "s1", "preferred_username" => lp}, server)
        assert id == hashed_id(lp, server)
        assert byte_size(id) == 255, "server #{server}"
        assert UserId.valid?(id)
      end
    end

    test "the hash is taken over the FULL SANITISED localpart (downcased, characters outside the grammar replaced by an underscore), not over the raw claim" do
      raw = String.duplicate("AbC ", 100)
      sanitised = raw |> String.downcase() |> String.replace(~r/[^a-z0-9._=\-\/+]/, "_")
      refute sanitised == raw

      id = UserId.from_claims(%{"sub" => "s1", "preferred_username" => raw}, @server)
      assert id == hashed_id(sanitised, @server)
      assert UserId.valid?(id)
    end

    test "deterministic: the same claims give the same id, through the standard claim chain, through the sub fallback and through the CONFIGURED claim" do
      long = String.duplicate("q", 600)

      via_username = %{"sub" => "s1", "preferred_username" => long}
      assert UserId.from_claims(via_username, @server) == UserId.from_claims(via_username, @server)

      via_sub = %{"sub" => long}
      assert UserId.from_claims(via_sub, @server) == hashed_id(long, @server)
      assert UserId.from_claims(via_sub, @server) == UserId.from_claims(via_sub, @server)

      configure_claim("employee_number")
      via_configured = %{"sub" => "s1", "preferred_username" => "short", "employee_number" => long}
      assert UserId.from_claims(via_configured, @server) == hashed_id(long, @server)
      assert byte_size(UserId.from_claims(via_configured, @server)) == 255
      assert UserId.from_claims(via_configured, @server) == UserId.from_claims(via_configured, @server)
    end

    test "two 1 000-character claims that share their first 300 characters get DIFFERENT ids (the hash covers the whole claim), both within 255 bytes" do
      common = String.duplicate("c", 300)
      one = common <> String.duplicate("1", 700)
      two = common <> String.duplicate("2", 700)

      id1 = UserId.from_claims(%{"sub" => "s", "preferred_username" => one}, @server)
      id2 = UserId.from_claims(%{"sub" => "s", "preferred_username" => two}, @server)

      refute id1 == id2
      assert byte_size(id1) <= 255 and byte_size(id2) <= 255
      assert UserId.valid?(id1) and UserId.valid?(id2)
    end

    test "a claim one byte longer than another with the same 255-byte prefix gets a different id (256 vs 257 bytes)" do
      lp256 = localpart_for(256, @server)
      lp257 = localpart_for(257, @server)

      refute UserId.from_claims(%{"sub" => "s", "preferred_username" => lp256}, @server) ==
               UserId.from_claims(%{"sub" => "s", "preferred_username" => lp257}, @server)
    end

    test "a normal claim is untouched: alice -> @alice:<server> exactly (regression pin), also with a long server name" do
      assert UserId.from_claims(%{"sub" => "s1", "preferred_username" => "alice"}, @server) == "@alice:test.local"
      assert UserId.from_claims(%{"sub" => "s1", "preferred_username" => "Alice"}, @server) == "@alice:test.local"
      assert UserId.from_claims(%{"sub" => "Opaque-SUB"}, @long_server) == "@opaque-sub:" <> @long_server
    end

    test "the id of a claim at the boundary is unchanged for a long server name too: 254 bytes -> as is, 255 and 256 -> hashed" do
      at = localpart_for(254, @long_server)
      over = localpart_for(255, @long_server)
      over2 = localpart_for(256, @long_server)

      assert UserId.from_claims(%{"sub" => at}, @long_server) == "@" <> at <> ":" <> @long_server
      assert UserId.from_claims(%{"sub" => over}, @long_server) == hashed_id(over, @long_server)
      assert UserId.from_claims(%{"sub" => over2}, @long_server) == hashed_id(over2, @long_server)
    end
  end

  describe "AC11 (a) - the SANITISED localpart is bounded (multi-byte claims)" do
    # sanitize/1 uses a regex without the `u` flag: EVERY non-ASCII BYTE of a claim becomes one underscore (an e-acute is 2 bytes -> "__", an emoji 4 -> "____").
    # The bound applies to the sanitised localpart (ASCII), so the expected ids are computed here from the underscore count, independently of the code.
    # 121 x e-acute: 242 + 12 = 254 bytes (the last natural id); 122 x: 256. 60 x emoji: 252; 61 x: 256.
    for {label, char, bytes_per_char, fits, over} <- [{"e-acute", "é", 2, 121, 122}, {"emoji", "😀", 4, 60, 61}] do
      test "#{label} claims: #{fits} characters sanitise to #{fits * bytes_per_char} underscores (unchanged), #{over} to #{over * bytes_per_char} (hashed)" do
        for {n, expect} <- [{unquote(fits), :unchanged}, {unquote(over), :hashed}] do
          sanitised = String.duplicate("_", n * unquote(bytes_per_char))
          id = UserId.from_claims(%{"sub" => "s", "preferred_username" => String.duplicate(unquote(char), n)}, @server)

          case expect do
            :unchanged -> assert id == "@" <> sanitised <> ":" <> @server, "#{n} characters"
            :hashed -> assert id == hashed_id(sanitised, @server), "#{n} characters"
          end

          assert byte_size(id) <= 255 and UserId.valid?(id)
        end
      end
    end

    test "127, 128 and 130 e-acute: all above the bound once sanitised, hashed over the underscores, 255 bytes, valid" do
      for n <- [127, 128, 130] do
        id = UserId.from_claims(%{"sub" => "s", "preferred_username" => String.duplicate("é", n)}, @server)
        assert id == hashed_id(String.duplicate("_", 2 * n), @server), "#{n} x e-acute"
        assert byte_size(id) == 255 and UserId.valid?(id)
      end
    end
  end

  describe "AC11 (a) - short-room server names (hashed form) and the config check boundary" do
    # a valid server name of exactly `n` bytes
    defp server_of(n), do: String.duplicate("s", n - 4) <> ".org"

    test "server names of 218, 219, 220 and 235 bytes (18, 17, 16 and 1 bytes of prefix left): the hashed form, exactly 255 bytes" do
      lp = String.duplicate("x", 400)

      for n <- [218, 219, 220, 235] do
        server = server_of(n)
        assert byte_size(server) == n
        id = UserId.from_claims(%{"sub" => lp}, server)
        assert id == hashed_id(lp, server), "server of #{n} bytes"
        assert byte_size(id) == 255 and UserId.valid?(id)
      end
    end

    test "UserId.server_name_leaves_room?/1: 235 bytes leave 18 localpart bytes (ok), 236 leave 17 (not ok); tiny and ordinary names are ok" do
      assert UserId.server_name_leaves_room?(server_of(235))
      refute UserId.server_name_leaves_room?(server_of(236))
      refute UserId.server_name_leaves_room?(server_of(237))
      refute UserId.server_name_leaves_room?(server_of(238))
      refute UserId.server_name_leaves_room?(server_of(300))
      assert UserId.server_name_leaves_room?(server_of(234))
      assert UserId.server_name_leaves_room?("test.local")
      assert UserId.server_name_leaves_room?("a.b")
    end

    test "the smallest hashed form of the largest accepted server name: 1 byte of prefix, a dash, 16 hex" do
      server = server_of(235)
      id = UserId.from_claims(%{"sub" => String.duplicate("q", 300)}, server)
      assert [_, lp] = Regex.run(~r/\A@(.*):/, id)
      assert byte_size(lp) == 18 and String.starts_with?(lp, "q-")
    end
  end

  describe "valid_shape?/1 - the grammar without the length bound (removal of a stored legacy id)" do
    test "an id above 255 bytes has the shape but is not valid?; a malformed id has neither" do
      long = "@" <> String.duplicate("a", 300) <> ":" <> @server
      assert byte_size(long) > 255
      assert UserId.valid_shape?(long)
      refute UserId.valid?(long)

      assert UserId.valid_shape?("@alice:test.local") and UserId.valid?("@alice:test.local")

      for bad <- ["alice:test.local", "@Alice:test.local", "@alice:test.local\n", "@:test.local", "@a b:test.local", nil, 42] do
        refute UserId.valid_shape?(bad), inspect(bad)
      end
    end
  end

  describe "AC11 (a) source pin - from_claims/2 is the only identity source" do
    test "no file under server/lib builds a user id from claims with a literal \"@\" <> besides user_id.ex" do
      lib = Path.expand("../../../lib", __DIR__)
      files = Path.wildcard(Path.join(lib, "**/*.ex"))
      assert length(files) > 100, "positive control: the lib tree was found"

      offenders =
        for file <- files,
            Path.basename(file) != "user_id.ex",
            src = File.read!(file),
            Regex.match?(~r/"@"\s*<>|"@\#\{/, src),
            do: Path.relative_to(file, lib)

      assert offenders == [], "user ids are built by Nebu.Matrix.UserId only: #{inspect(offenders)}"
    end
  end

  describe "AC11 (b) - UserId.valid?/1 carries the same bound" do
    test "a 255-byte id is valid, a 256-byte id is not (also with a long server name)" do
      for server <- [@server, @long_server] do
        ok = "@" <> localpart_for(255, server) <> ":" <> server
        too_long = "@" <> localpart_for(256, server) <> ":" <> server
        assert byte_size(ok) == 255 and byte_size(too_long) == 256
        assert UserId.valid?(ok), "255 bytes, server #{server}"
        refute UserId.valid?(too_long), "256 bytes, server #{server}"
      end
    end

    test "the grammar is unchanged: ordinary ids stay valid, malformed ones stay invalid" do
      assert UserId.valid?("@alice:test.local")
      assert UserId.valid?("@a.b_c=d-e/f+g:matrix.example.org")
      refute UserId.valid?("alice:test.local")
      refute UserId.valid?("@Alice:test.local")
      refute UserId.valid?("@alice:test.local\n")
      refute UserId.valid?(nil)
    end
  end
end
