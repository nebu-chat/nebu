defmodule Nebu.Admin.SessionLifetimeParserTest do
  @moduledoc """
  Story `session-lifetime-setting`, CYCLE 1 (code review MINOR 2): ONE parser / validator of the bounded lifetime value, in `Nebu.OAuth.Config` and exposed through
  the `Nebu.OAuth` facade as `Nebu.OAuth.parse_matrix_session_ttl/1` (`{:ok, seconds} | :error`; text is trimmed, plain decimal digits, `3600..7_776_000`; an
  integer inside the bounds is accepted too). The Admin form (`OAuthSwitch.validate_session_lifetime/1`) and the runtime reader (`Nebu.OAuth.matrix_session_ttl_seconds/0`
  behind `SessionConfig`) both use it, so they can never disagree: what the form refuses the reader ignores, what the reader accepts the form saves. Before the fix
  the reader (`Integer.parse`) accepted `"+7200"` and a long run of leading zeros that the form (regex) refused.
  No database: the reader is fed through the `:oauth_config_source` seam.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L

  @accepted ["3600", "7200", " 7200", "7200 ", " 7200 ", "\t7200\n", "28800", "86400", "7776000"]
  @refused ["+7200", "-7200", "7_200", "7,200", "7200.0", "7200.5", "1e4", "0x1C20", "abc", "", " ", "\n", "3599", "7776001", "0", "100", "2 hours", "7200s", "72\n00", "７２００", "٧٢٠٠", "99999999999999999999999"]
  # accepted or refused is not pinned (the one parser decides), but ALL THREE entry points must give the same answer
  @ambiguous ["07200", "0007200", "0000000007200", "007776000", "+0", "3600\n", "\v7200", "7200 ", " 7200"]

  setup do
    T.clear_oauth_config()
    L.clear_env_ttl!()
    on_exit(&T.clear_oauth_config/0)
    :ok
  end

  defp parser(raw), do: apply(Nebu.OAuth, :parse_matrix_session_ttl, [raw])
  defp form(raw), do: apply(Nebu.Admin.OAuthSwitch, :validate_session_lifetime, [raw])

  # what the runtime makes of a stored text: the saved value, or nil when it is ignored (damaged / out of range)
  defp reader(raw) do
    L.seam_stored(raw)
    {value, _log} = with_log(fn -> Nebu.OAuth.matrix_session_ttl_seconds() end)
    value
  end

  defp verdicts(raw) do
    form_verdict =
      case form(raw) do
        {:ok, n} -> {:ok, n}
        {:error, _message} -> :error
      end

    reader_verdict =
      case reader(raw) do
        nil -> :error
        n -> {:ok, n}
      end

    {parser(raw), form_verdict, reader_verdict}
  end

  test "the facade exposes the one parser" do
    assert Code.ensure_loaded?(Nebu.OAuth)
    assert function_exported?(Nebu.OAuth, :parse_matrix_session_ttl, 1)
  end

  test "values that are valid are accepted by the parser, the form and the reader alike, with the same number" do
    for raw <- @accepted do
      n = raw |> String.trim() |> String.to_integer()
      assert {{:ok, ^n}, {:ok, ^n}, {:ok, ^n}} = verdicts(raw), inspect(raw)
    end
  end

  test "values that are not valid are refused by the parser and the form and IGNORED by the reader" do
    for raw <- @refused do
      assert {:error, :error, :error} == verdicts(raw), inspect(raw)
    end
  end

  test "the three entry points never disagree, whatever the text" do
    for raw <- @accepted ++ @refused ++ @ambiguous do
      {p, f, r} = verdicts(raw)
      assert p == f and f == r, "#{inspect(raw)}: parser #{inspect(p)}, form #{inspect(f)}, reader #{inspect(r)}"
    end
  end

  test "an integer is read by the reader and the parser the same way (inside the bounds only)" do
    for n <- [3600, 7200, 7_776_000] do
      assert parser(n) == {:ok, n}
      assert reader(n) == n
    end

    for n <- [0, 3599, 7_776_001, -7200] do
      assert parser(n) == :error
      assert reader(n) == nil
    end
  end

  test "anything that is not text or an integer is :error (never raises)" do
    for raw <- [nil, :atom, ["7200"], %{"a" => 7200}, 7200.0] do
      assert parser(raw) == :error, inspect(raw)
    end
  end

  test "the bounds the parser applies are exactly Nebu.OAuth.matrix_session_ttl_bounds/0" do
    {min, max} = Nebu.OAuth.matrix_session_ttl_bounds()
    assert parser(Integer.to_string(min)) == {:ok, min}
    assert parser(Integer.to_string(max)) == {:ok, max}
    assert parser(Integer.to_string(min - 1)) == :error
    assert parser(Integer.to_string(max + 1)) == :error
  end

  describe "the reader that reads the REAL row (not the seam) judges like the form and the parser" do
    @describetag :integration

    setup do
      L.delete_row!()
      :ok
    end

    test "every text of the lists above: same verdict from the parser, the form and the reader of the saved row" do
      for raw <- @accepted ++ @refused ++ @ambiguous, not String.contains?(raw, <<0>>) do
        # no earlier good value may hide a damaged row (last-known-good), and the TTL cache is off in the test config
        L.reset_last_good!()
        L.set_row!(raw)
        {read, _log} = with_log(fn -> Nebu.OAuth.matrix_session_ttl_seconds() end)
        reader_verdict = if read, do: {:ok, read}, else: :error

        form_verdict =
          case form(raw) do
            {:ok, n} -> {:ok, n}
            {:error, _} -> :error
          end

        assert parser(raw) == form_verdict and form_verdict == reader_verdict, "#{inspect(raw)}: parser #{inspect(parser(raw))}, form #{inspect(form_verdict)}, row reader #{inspect(reader_verdict)}"
      end
    end
  end
end
