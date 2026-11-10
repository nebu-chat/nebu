defmodule Nebu.OAuth.DeviceNamePlanBlankTest do
  @moduledoc """
  Bugfix `matrix-put-device-keeps-display-name`, scenario "A stored blank name counts as a name for the Allow page plan": the PURE part (no database).

  `Nebu.OAuth.DeviceName.plan/3` treated a stored blank (non-NULL) `display_name` as "no name", so the Allow page's remembered-Allow path would replace it
  (`insert_replacing_device` drops the typed name). A stored `""` or whitespace-only value is a name that was SET: `{:existing, stored}`, returned verbatim;
  only NULL (`nil`) means "no name" (derive or ask).
  """
  use ExUnit.Case, async: true

  alias Nebu.OAuth.DeviceName

  @dev "ABCD1234"
  @named %{"client_name" => "FluffyChat"}
  @nameless %{}

  # Scenario: A stored blank name counts as a name for the Allow page plan
  @tag ac: "a-stored-blank-name-counts-as-a-name-for-the-allow-page-plan"
  test "a stored empty string is an existing name (the typed / derived name does not replace it)" do
    assert DeviceName.plan(@named, @dev, "") == {:existing, ""}
  end

  @tag ac: "a-stored-blank-name-counts-as-a-name-for-the-allow-page-plan"
  test "a stored whitespace-only name is an existing name, returned verbatim" do
    assert DeviceName.plan(@named, @dev, "   ") == {:existing, "   "}
  end

  @tag ac: "a-stored-blank-name-counts-as-a-name-for-the-allow-page-plan"
  test "a stored blank name wins even when nothing can be derived: the page must not ask" do
    assert DeviceName.plan(@nameless, @dev, "") == {:existing, ""}
    assert DeviceName.plan(@nameless, @dev, "") != :ask
    assert DeviceName.plan(@nameless, @dev, " \t ") == {:existing, " \t "}
  end

  @tag ac: "a-stored-blank-name-counts-as-a-name-for-the-allow-page-plan"
  test "NULL (nil) is still 'no name': the plan derives from the client record" do
    assert DeviceName.plan(@named, @dev, nil) == {:derived, "FluffyChat (ABCD1234)"}
  end

  @tag ac: "a-stored-blank-name-counts-as-a-name-for-the-allow-page-plan"
  test "NULL (nil) with nothing derivable still asks" do
    assert DeviceName.plan(@nameless, @dev, nil) == :ask
  end

  @tag ac: "a-stored-blank-name-counts-as-a-name-for-the-allow-page-plan"
  test "a normal stored name is still existing (regression)" do
    assert DeviceName.plan(@named, @dev, "Work laptop") == {:existing, "Work laptop"}
  end
end
