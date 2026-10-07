defmodule Nebu.Matrix.PageTokenTest do
  @moduledoc """
  Unit tests for `Nebu.Matrix.PageToken`. `Nebu.Matrix.PageToken`'s moduledoc
  makes an explicit claim — a mutual_rooms token can never be replayed as a
  hierarchy token and vice versa, because the prefix check fails closed. This
  file asserts that invariant directly, plus the encode/decode round-trip and
  the edge cases `decode/2` must fail closed on: zero/negative offsets,
  non-base64 input, and non-binary input.
  """

  use ExUnit.Case, async: true

  alias Nebu.Matrix.PageToken

  describe "cross-prefix rejection (the moduledoc's claimed invariant)" do
    test "a mutual_rooms (\"mr1:\") token is rejected when decoded with the hierarchy (\"h1:\") prefix" do
      token = PageToken.encode("mr1:", 3)
      assert PageToken.decode("h1:", token) == {:error, :invalid_token}
    end

    test "symmetric reverse: a hierarchy (\"h1:\") token is rejected when decoded with the mutual_rooms (\"mr1:\") prefix" do
      token = PageToken.encode("h1:", 3)
      assert PageToken.decode("mr1:", token) == {:error, :invalid_token}
    end
  end

  describe "round-trip" do
    test "decode(prefix, encode(prefix, offset)) == {:ok, offset} for several values" do
      for {prefix, offset} <- [{"mr1:", 0}, {"mr1:", 1}, {"h1:", 5}, {"h1:", 1000}] do
        token = PageToken.encode(prefix, offset)
        assert PageToken.decode(prefix, token) == {:ok, offset}
      end
    end
  end

  describe "decode/2 edge cases" do
    test "offset 0 round-trips correctly (not confused with a falsy/absent value)" do
      token = PageToken.encode("mr1:", 0)
      assert PageToken.decode("mr1:", token) == {:ok, 0}
    end

    test "a token encoding a negative offset fails closed (encode/2 itself guards against this, so this simulates a forged token)" do
      # encode/2 has a guard requiring offset >= 0, so a negative offset can
      # only arise from a forged/hand-built token — construct one directly to
      # exercise decode/2's own `offset >= 0` fail-closed check.
      forged = Base.url_encode64("mr1:-5", padding: false)
      assert PageToken.decode("mr1:", forged) == {:error, :invalid_token}
    end

    test "non-base64 input fails closed" do
      assert PageToken.decode("mr1:", "not valid base64!!!") == {:error, :invalid_token}
    end

    test "base64 input that decodes to something not starting with the prefix fails closed" do
      token = Base.url_encode64("totally-unrelated-payload", padding: false)
      assert PageToken.decode("mr1:", token) == {:error, :invalid_token}
    end

    test "base64 input that decodes to the prefix plus non-numeric trailing data fails closed" do
      token = Base.url_encode64("mr1:not-a-number", padding: false)
      assert PageToken.decode("mr1:", token) == {:error, :invalid_token}
    end

    test "base64 input that decodes to the prefix plus a number with trailing garbage fails closed" do
      token = Base.url_encode64("mr1:5garbage", padding: false)
      assert PageToken.decode("mr1:", token) == {:error, :invalid_token}
    end

    test "non-binary token input fails closed" do
      assert PageToken.decode("mr1:", 12345) == {:error, :invalid_token}
      assert PageToken.decode("mr1:", nil) == {:error, :invalid_token}
      assert PageToken.decode("mr1:", :not_a_string) == {:error, :invalid_token}
    end

    test "non-binary prefix input fails closed" do
      token = PageToken.encode("mr1:", 2)
      assert PageToken.decode(nil, token) == {:error, :invalid_token}
      assert PageToken.decode(123, token) == {:error, :invalid_token}
    end
  end
end
