defmodule Nebu.Web.Plugs.RawBodyReaderShapeTest do
  @moduledoc """
  Pure (DB-free) test of the account-data path matcher used by `RawBodyReader`:
  it must split segments exactly like Plug.Router does (decode, drop empty segments,
  tolerate invalid percent-encoding).

  Lives in its own module because `RoomAccountDataHardeningTest` provisions a user and a
  room in its `setup` (needs `Nebu.Repo`), which fails in the DB-free unit run.
  """

  use ExUnit.Case, async: true

  describe "path normalization (shape helper)" do
    alias Nebu.Web.Plugs.RawBodyReader, as: R

    test "decodes segments, drops empty segments, tolerates invalid percent-encoding" do
      assert R.account_data_shape?("/_matrix/client/v3/user/@a:b/%61ccount_data/t")
      assert R.account_data_shape?("/_matrix/client/v3/user/@a:b/rooms/!r/%61ccount_data/t")
      assert R.account_data_shape?("/_matrix//client/v3//user/@a:b/account_data/t")
      assert R.account_data_shape?("/_matrix/client/v3/user/@a:b/account_data/t/")
      assert R.account_data_shape?(["_matrix", "client", "v3", "user", "u", "%61ccount_data", "t"])
      refute R.account_data_shape?("/_matrix/client/v3/user/@a:b/account_data/%zz/x")
      assert R.account_data_shape?("/_matrix/client/v3/user/@a:b/account_data/%zz")
      refute R.account_data_shape?("/_matrix/client/v3/rooms/!r/send/m.room.message/%61ccount_data")
    end
  end
end
