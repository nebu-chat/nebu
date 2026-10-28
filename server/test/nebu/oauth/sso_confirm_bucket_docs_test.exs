defmodule Nebu.OAuth.SsoConfirmBucketDocsTest do
  @moduledoc """
  Static checks (no DB) for story `sso-confirm-bucket-order` (follow-up `cv`), AC7: ADR-033 L9, the G3-2 row of 07-deployment (the confirmation page is no
  longer affected by the collapse), follow-ups (`cv` closed, `di`) and the concepts text.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  defp read(rel), do: Path.join(@root, rel) |> File.read!() |> String.replace(~r/\s+/, " ")

  test "ADR-033 L9 describes the cookie-first counting, both buckets, the changed POST answers and the residual" do
    a = read("docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
    [_, rest] = String.split(a, "- **L9 Counting by the binding cookie", parts: 2)
    l9 = rest |> String.split("- **L8 Residuals", parts: 2) |> hd()
    for word <- ["`{\"sso_confirm\", hex(SHA-256(cookie))}`", "`{\"sso_confirm_miss\", ip}`", "`invalid_state`", "HIT", "MISS", "G3-2", "cookie-less POST", "follow-up `di`"], do: assert(l9 =~ word, word)
  end

  test "07-deployment: the G3-2 row no longer says that the confirmation page is locked by the collapse" do
    d = read("docs/architecture/07-deployment.md")
    refute d =~ "its per-client-address bucket is charged before the cookie check"
    assert d =~ "story sso-confirm-bucket-order"
  end

  test "follow-ups: cv is closed, di exists; 08-concepts names the new order" do
    f = read("docs/stories/oauth-broker/follow-ups.md")
    assert f =~ "| cv | **CLOSED by story sso-confirm-bucket-order"
    assert f =~ "| di |"
    assert read("docs/architecture/08-concepts.md") =~ "story sso-confirm-bucket-order"
  end
end
