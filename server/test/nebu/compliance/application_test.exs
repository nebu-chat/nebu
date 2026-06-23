defmodule Nebu.Compliance.ApplicationTest do
  use ExUnit.Case, async: false

  # Story 5-2 AC2 — Nebu.Compliance is a stateless domain in the single :nebu OTP app
  # (ADR-019; formerly its own umbrella app). AuditWriter is a pure module function,
  # so there is no GenServer to supervise; Nebu.Compliance.Supervisor (started by
  # Nebu.Application) returns an empty children list. This test locks that contract
  # in so a future accidental GenServer addition doesn't silently slip past AC2's
  # Option C classification.

  test "the single :nebu app is started" do
    {:ok, _started} = Application.ensure_all_started(:nebu)
    started_names = Enum.map(Application.started_applications(), fn {name, _, _} -> name end)
    assert :nebu in started_names
  end

  test "Nebu.Compliance.Supervisor exposes an empty children list (Option C stateless)" do
    {:ok, _} = Application.ensure_all_started(:nebu)
    sup_pid = Process.whereis(Nebu.Compliance.Supervisor)

    assert is_pid(sup_pid),
           "Nebu.Compliance.Supervisor should be running under the :nebu app"

    children = Supervisor.which_children(sup_pid)

    assert children == [],
           "AC2 (Option C stateless) requires Nebu.Compliance.Supervisor children=[] in test. " <>
             "Got: #{inspect(children)}. If a genuine GenServer worker is needed, " <>
             "update AC2 in the story and add the corresponding crash/restart test."
  end
end
