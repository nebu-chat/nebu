defmodule Nebu.Matrix.DeviceListStoreTokenTest do
  @moduledoc "Unit pins of the device-list position group of the sync token (story device-key-directory, D11): no database."
  use ExUnit.Case, async: true

  alias Nebu.Matrix.DeviceListStore

  describe "strip_position/1" do
    test "splits a last group .d<digits> off the token" do
      assert DeviceListStore.strip_position("s2_abc.5.d42") == {"s2_abc.5", 42}
      assert DeviceListStore.strip_position("s2_abc.5.6.d0") == {"s2_abc.5.6", 0}
    end

    test "a token without the group is returned as it is with nil" do
      assert DeviceListStore.strip_position("s2_abc.5") == {"s2_abc.5", nil}
      assert DeviceListStore.strip_position("s2_abc.5.dx") == {"s2_abc.5.dx", nil}
      assert DeviceListStore.strip_position(nil) == {nil, nil}
    end

    test "a group whose number does not fit an int8 is STRIPPED and the position is nil (the conservative answer)" do
      assert DeviceListStore.strip_position("s2_abc.5.d9223372036854775808") == {"s2_abc.5", nil}
      assert DeviceListStore.strip_position("s2_abc.5.d99999999999999999999") == {"s2_abc.5", nil}
      assert DeviceListStore.strip_position("s2_abc.5.d9223372036854775807") == {"s2_abc.5", 9_223_372_036_854_775_807}
    end

    test "put_position/2 is the inverse; nil appends nothing" do
      assert DeviceListStore.put_position("s2_abc.5", 42) == "s2_abc.5.d42"
      assert DeviceListStore.put_position("s2_abc.5", nil) == "s2_abc.5"
      assert DeviceListStore.strip_position(DeviceListStore.put_position("s2_abc.5", 7)) == {"s2_abc.5", 7}
    end
  end
end
