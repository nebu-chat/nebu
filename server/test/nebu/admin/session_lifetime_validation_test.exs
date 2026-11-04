defmodule Nebu.Admin.SessionLifetimeValidationTest do
  @moduledoc """
  Story `session-lifetime-setting`, scenario 3 (the pure part, no database, no conn): `Nebu.Admin.OAuthSwitch.validate_session_lifetime/1` turns the
  submitted text of the lifetime field into `{:ok, seconds}` or `{:error, message}`, and `Nebu.Admin.OAuthSwitch.lifetime_text/1` prints a number of
  seconds as the human text the form shows next to the field ("8 hours").

  Rules pinned: whole seconds as plain decimal digits (surrounding white space is trimmed), `3600..7_776_000` (1 hour .. 90 days); everything else
  (blank, a sign, a decimal point, an exponent, a unit, digit separators, a list or map: parameter pollution, a huge number) is an error whose message
  names the two bounds in seconds. The numbers are the same as those of `Nebu.Web.SessionConfig`'s stored-value reader (see session_config_lifetime_test.exs).
  """
  use ExUnit.Case, async: true

  @switch Nebu.Admin.OAuthSwitch

  # `apply/3`: the functions are new in this story, a plain call would be an undefined-function warning (an abort under `--warnings-as-errors`) before they exist
  defp validate(raw), do: apply(@switch, :validate_session_lifetime, [raw])
  defp text(seconds), do: apply(@switch, :lifetime_text, [seconds])

  describe "validate_session_lifetime/1" do
    test "whole seconds inside the bounds are accepted, the bounds included" do
      for {raw, seconds} <- [{"3600", 3600}, {"7200", 7200}, {"28800", 28_800}, {"86400", 86_400}, {"7776000", 7_776_000}, {"3601", 3601}, {"7775999", 7_775_999}] do
        assert {:ok, ^seconds} = validate(raw), raw
      end
    end

    test "white space around the number is trimmed" do
      assert {:ok, 7200} = validate(" 7200 ")
      assert {:ok, 7200} = validate("\t7200\n")
    end

    test "below the minimum or above the maximum is refused (100 days is above the 90 day maximum)" do
      for raw <- ["3599", "1", "0", "60", "7776001", "8640000", "86400000", "99999999999999999999999"] do
        assert {:error, message} = validate(raw), raw
        assert is_binary(message)
      end
    end

    test "blank, signs, decimals, exponents, units, separators and other text are refused" do
      for raw <- ["", " ", "\n", "abc", "7200.5", "7200.0", "-7200", "+7200", "1e4", "7_200", "7,200", "0x1C20", "2 hours", "7200s", "7200 7200", "72\n00", "７２００", "٧٢٠٠", "7200;", "<script>"] do
        assert {:error, _message} = validate(raw), inspect(raw)
      end
    end

    test "nothing, a list or a map (parameter pollution) is refused, never raised on" do
      for raw <- [nil, ["7200"], %{"a" => "7200"}, :two_hours] do
        assert {:error, _message} = validate(raw), inspect(raw)
      end
    end

    test "the message names both bounds in seconds and says whole numbers, without echoing the submitted text" do
      assert {:error, message} = validate("canary-9911-text")
      assert message =~ "3600"
      assert message =~ "7776000"
      assert message =~ ~r/whole/i
      refute message =~ "canary-9911", "the message is fixed text, the submitted value is shown in the field only"

      assert {:error, above} = validate("8640000")
      assert above =~ "3600" and above =~ "7776000"
    end
  end

  describe "lifetime_text/1" do
    test "whole hours and days" do
      for {seconds, human} <- [{3600, "1 hour"}, {7200, "2 hours"}, {28_800, "8 hours"}, {86_400, "1 day"}, {172_800, "2 days"}, {7_776_000, "90 days"}, {43_200, "12 hours"}] do
        assert text(seconds) == human, "#{seconds}"
      end
    end

    test "mixed values name every non-zero unit" do
      assert text(90_000) =~ "1 day" and text(90_000) =~ "1 hour"
      assert text(5400) =~ "1 hour" and text(5400) =~ "30 minutes"
      assert text(3660) =~ "1 hour" and text(3660) =~ "1 minute"
    end

    test "a value that is not a whole number of minutes is shown in seconds (it must stay readable and exact)" do
      assert text(3601) =~ "3601"
    end
  end
end
