defmodule Nebu.Matrix.DeviceKeyDirectoryClaimBudgetTest do
  @moduledoc """
  Unit tests (NO database: the handler is called directly, the claim itself answers 200 or 500, only the limiter matters) of the rate bucket bookkeeping of
  `POST /keys/claim` (story device-key-directory, security finding F1, cycle 4):

    * the per-target bucket key is fixed size and never references the request body (a sub-binary of a decoded body in an ETS key pins the whole body);
    * a request refused by the caller buckets (stage 1) creates NO per-target row; the rows one account can create are bounded by the targets budget;
    * the pinned numbers of `HttpKeyDirectory.limits/0`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.HttpKeyDirectory
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @table :nebu_http_rate_limit_buckets
  @user "@budget:test.local"

  setup do
    T.reset_rate_limits()
    TD.enable_rate_limit()
    Nebu.Web.Plugs.RateLimit.init_table()
    :ets.delete_all_objects(@table)
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # a body decoded from JSON text like the real endpoint does (the decoded strings are sub-binaries of the text), `n` targets with 100 byte ids
  defp decoded_body(n, tag) do
    pad = String.duplicate("x", 90)
    targets = for i <- 1..n, into: %{}, do: {"@#{tag}#{i}#{pad}:test.local", %{"D#{i}#{pad}" => "signed_curve25519"}}
    json = Jason.encode!(%{"one_time_keys" => targets})
    {Jason.decode!(json), byte_size(json)}
  end

  defp claim(body_params, user \\ @user) do
    :post
    |> Plug.Test.conn("/_matrix/client/v3/keys/claim", "")
    |> Map.put(:body_params, body_params)
    |> Plug.Conn.assign(:current_user, user)
    |> HttpKeyDirectory.claim()
  end

  defp size, do: :ets.info(@table, :size)
  defp rows(tag), do: for({{^tag, _, _} = key, _, _} <- :ets.tab2list(@table), do: key)

  defp binaries(term) when is_binary(term), do: [term]
  defp binaries(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.flat_map(&binaries/1)
  defp binaries([h | t]), do: binaries(h) ++ binaries(t)
  defp binaries(_), do: []

  test "the pinned numbers" do
    assert HttpKeyDirectory.limits() == %{
             max_targets: 1000,
             user_per_min: 30,
             user_burst: 10,
             target_per_hour: 10,
             target_burst: 5,
             targets_per_min: 600,
             targets_burst: 1000
           }

    assert HttpKeyDirectory.limits() == DK.limits()
  end

  describe "the per-target bucket key" do
    test "is a fixed size digest and references no byte of the request body (a body of more than 50 KB)" do
      {body, bytes} = decoded_body(250, "a")
      assert bytes >= 50_000
      claim(body)

      keys = rows("keys_claim_target")
      assert length(keys) == 250, "one bucket per valid target"

      for {"keys_claim_target", user, digest} = key <- keys do
        assert user == @user
        assert byte_size(digest) == 32, "a SHA-256 digest"

        for b <- binaries(key) do
          assert :binary.referenced_byte_size(b) <= byte_size(b), "a key binary pins a larger binary (#{byte_size(b)} of #{:binary.referenced_byte_size(b)} bytes)"
        end
      end
    end

    test "is per (caller, user id, device id): another device, another user and another caller are other buckets; the same target is the same bucket" do
      t = fn uid, did -> %{"one_time_keys" => %{uid => %{did => "signed_curve25519"}}} end
      claim(t.("@u:test.local", "D1"))
      claim(t.("@u:test.local", "D1"))
      assert length(rows("keys_claim_target")) == 1
      claim(t.("@u:test.local", "D2"))
      claim(t.("@v:test.local", "D1"))
      claim(t.("@u:test.local", "D1"), "@other:test.local")
      assert length(rows("keys_claim_target")) == 4

      # the NUL separator is part of the digest input: ("@u:test.local", "D1") and ("@u:test.localD", "1") are different targets
      claim(t.("@u:test.localD", "1"))
      assert length(rows("keys_claim_target")) == 5
    end
  end

  describe "the table does not grow for a refused request" do
    test "a request refused in stage 1 (request bucket empty) creates no per-target row" do
      for i <- 1..10, do: claim(%{"one_time_keys" => %{"@g#{i}:test.local" => %{"D" => "signed_curve25519"}}})
      before = size()
      {body, _} = decoded_body(500, "b")
      assert claim(body).status == 429
      assert size() == before, "no row was created by the refused request"
    end

    test "a request refused in stage 1 (targets budget too small) creates no per-target row" do
      {first, _} = decoded_body(900, "c")
      assert claim(first).status != 429
      before = size()
      {second, _} = decoded_body(300, "d")
      assert claim(second).status == 429
      assert size() == before
    end

    test "the rows after allowed requests are bounded by the targets budget (plus the two caller rows)" do
      before = size()

      for i <- 1..9 do
        {body, _} = decoded_body(300, "e#{i}-")
        claim(body)
      end

      assert size() - before <= HttpKeyDirectory.limits().targets_burst + 2
      assert length(rows("keys_claim_target")) <= HttpKeyDirectory.limits().targets_burst
    end

    test "the cost depends on the number of syntactically valid targets only: invalid ids cost nothing, an empty request charges only the request bucket" do
      claim(%{"one_time_keys" => %{"not-a-user" => %{"D" => "signed_curve25519"}, "@x:test.local" => %{"" => "signed_curve25519"}}})
      assert rows("keys_claim_target") == []
      assert :ets.lookup(@table, {"keys_claim_targets", @user}) == []
      claim(%{"one_time_keys" => %{}})
      assert :ets.lookup(@table, {"keys_claim_targets", @user}) == []
      assert [{_, tokens, _}] = :ets.lookup(@table, {"keys_claim", @user})
      assert tokens == 8.0
    end
  end

  describe "the 429" do
    test "does not depend on the targets: drained targets budget answers 429 for any target alike" do
      {big, _} = decoded_body(1000, "f")
      assert claim(big).status != 429

      answers =
        for body <- [
              %{"one_time_keys" => %{"@a:test.local" => %{"D" => "signed_curve25519"}}},
              %{"one_time_keys" => %{"@b:test.local" => %{"D" => "signed_curve25519"}}},
              %{"one_time_keys" => %{"@f1#{String.duplicate("x", 90)}:test.local" => %{"D1#{String.duplicate("x", 90)}" => "signed_curve25519"}}}
            ] do
          c = claim(body)
          {c.status, TD.json(c)["errcode"], TD.json(c)["retry_after_ms"]}
        end

      assert Enum.uniq(answers) == [{429, "M_LIMIT_EXCEEDED", 1000}], inspect(answers)
    end
  end
end
