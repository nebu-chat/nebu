"""Mutants of cycle 4 (to-device-messaging): the send is two transactions (rows, then the soft eviction); KEY SHARE only around the INSERT.
Run from the repo root with reference-impl-cycle4.diff applied on top of the committed tree:
  python3 .../mutation/check.py .../mutation/mutants_c4.py ; python3 .../mutation/mutate.py .../mutation/mutants_c4.py <log> [ids]
"""
ST = "server/lib/nebu/matrix/to_device_store.ex"
RISK = "docs/architecture/11-risks.md"
CON = "docs/architecture/08-concepts.md"
DEP = "docs/architecture/07-deployment.md"
CL = "CHANGELOG.md"
T = "test/nebu/matrix/"
TP = T + "to_device_two_phase_send_test.exs"
DOCS = T + "to_device_docs_test.exs"
CONC = T + "to_device_concurrency_test.exs"
DF = T + "to_device_delivery_faults_test.exs"
SB = T + "to_device_sender_budget_test.exs"
LOG = T + "to_device_logging_test.exs"

SEND_OLD = """    result =
      transact(fn ->
        with {:ok, _} <- set_timeouts(),
             :ok <- lock_sender(sender),
             {:ok, fresh?} <- record_txn(sender, sender_device, event_type, txn_id) do
          if fresh?, do: enqueue(sender, sender_device, event_type, entries), else: {:ok, {:duplicate, []}}
        end
      end)
"""
SEND_NEW = """    {:ok, fresh?} = record_txn(sender, sender_device, event_type, txn_id)

    result =
      transact(fn ->
        with {:ok, _} <- set_timeouts(),
             :ok <- lock_sender(sender) do
          if fresh?, do: enqueue(sender, sender_device, event_type, entries), else: {:ok, {:duplicate, []}}
        end
      end)
"""
INS_OLD = "             ) do\n        {:ok, {Enum.map(targets, fn {u, d, _c} -> {u, d} end), us, ds}}\n      end"
INS_NEW = "             ),\n           {:ok, _} <- evict(sender, us, ds) do\n        {:ok, {Enum.map(targets, fn {u, d, _c} -> {u, d} end), us, ds}}\n      end"

MUTANTS = [
  dict(id="N01", label="phase 2 takes FOR KEY SHARE on the devices rows again (eviction lock on devices)", file=ST,
       old="with {:ok, _} <- set_timeouts(), do: evict(sender, us, ds)",
       new="with {:ok, _} <- set_timeouts(),\n             {:ok, _} <- query(\"SELECT 1 FROM devices WHERE (user_id, device_id) IN (SELECT * FROM unnest($1::text[], $2::text[])) FOR KEY SHARE\", [us, ds]),\n             do: evict(sender, us, ds)", tests=TP),
  dict(id="N02", label="phase 2 takes FOR UPDATE on the devices rows", file=ST,
       old="with {:ok, _} <- set_timeouts(), do: evict(sender, us, ds)",
       new="with {:ok, _} <- set_timeouts(),\n             {:ok, _} <- query(\"SELECT 1 FROM devices WHERE (user_id, device_id) IN (SELECT * FROM unnest($1::text[], $2::text[])) FOR UPDATE\", [us, ds]),\n             do: evict(sender, us, ds)", tests=TP),
  dict(id="N03", label="the eviction runs inside phase 1 again (the key share lives through it)", file=ST, edits=[(ST, INS_OLD, INS_NEW)], tests=TP),
  dict(id="N04", label="a phase 2 error is propagated (the send fails)", file=ST,
       edits=[(ST, "        settle(sender, us, ds)\n        :ok\n", "        with :ok <- settle(sender, us, ds), do: :ok\n"),
              (ST, "the queues catch up with the next send\")\n", "the queues catch up with the next send\")\n        {:error, reason}\n")], tests=TP),
  dict(id="N05", label="phase 2 is skipped entirely", file=ST, old="        settle(sender, us, ds)\n        :ok\n", new="        _ = {us, ds}\n        :ok\n", tests=TP + " " + SB),
  dict(id="N06", label="phase 2 runs without its own timeouts", file=ST, old="with {:ok, _} <- set_timeouts(), do: evict(sender, us, ds)", new="evict(sender, us, ds)", tests=TP),
  dict(id="N07", label="the failed eviction logs the database error, not the kind", file=ST, old="the eviction failed (#{error_kind(reason)})", new="the eviction failed (#{inspect(reason)})", tests=TP),
  dict(id="N08", label="the wake-up comes after phase 2", file=ST, old="        wake(targets)\n        # PHASE 2 (a second transaction after the commit, best effort, no lock on `devices`): the soft eviction. It never fails the send.\n        settle(sender, us, ds)\n",
       new="        settle(sender, us, ds)\n        wake(targets)\n", tests=TP),
  dict(id="N09", label="phase 2 evicts nothing for the touched devices (empty target arrays)", file=ST, old="        settle(sender, us, ds)\n        :ok\n", new="        settle(sender, [], [])\n        :ok\n", tests=TP + " " + SB),
  dict(id="N10", label="phase 2 runs asynchronously after the response (no quiescent state at the answer)", file=ST, old="        settle(sender, us, ds)\n        :ok\n", new="        Task.start(fn -> settle(sender, us, ds) end)\n        :ok\n", tests=TP),
  dict(id="N11", label="the transaction record is written outside the first transaction", file=ST, edits=[(ST, SEND_OLD, SEND_NEW)], tests=TP + " " + LOG),
  dict(id="N12", label="phase 2 also runs for a recorded (duplicate) transaction", file=ST, old="      {:ok, {:duplicate, _}} ->\n        :ok\n", new="      {:ok, {:duplicate, _}} ->\n        settle(sender, [], [])\n        :ok\n", tests=TP),
  dict(id="N13", label="the target lookup of explicit devices loses its FOR KEY SHARE (the cycle 0 device-delete race is back)", file=ST, old="IN (SELECT * FROM unnest($1::text[], $2::text[])) FOR KEY SHARE\"", new="IN (SELECT * FROM unnest($1::text[], $2::text[]))\"", tests=TP + " " + DF),
  dict(id="N14", label="the `*` lookup loses its FOR KEY SHARE", file=ST, old="LIMIT $2 FOR KEY SHARE) d", new="LIMIT $2) d", tests=TP + " " + DF),
  dict(id="N15", label="docs: 11-risks (12) is an accepted residual again", file=RISK, old="(12) CLOSED in cycle 4", new="(12) accepted in cycle 4", tests=DOCS),
  dict(id="N16", label="docs: 11-risks (12) loses the failed-eviction residual", file=RISK, old="a failed or timed-out eviction leaves the excess until the next send", new="a failed or timed-out eviction is retried", tests=DOCS),
  dict(id="N17", label="docs: 08-concepts says the key share lives until the commit", file=CON, old="only around its INSERT (the soft eviction runs afterwards in a second, separate transaction without any lock on `devices`;", new="until its commit (the soft eviction runs together with it without any lock on `devices`;", tests=DOCS),
  dict(id="N18", label="docs: 07-deployment loses the two-transaction note", file=DEP, old="a send is two transactions (the rows, then the soft eviction in a second transaction after the commit), so the caps are momentarily soft", new="the caps are soft", tests=DOCS),
  dict(id="N19", label="docs: CHANGELOG loses the second-transaction line", file=CL, old="the soft eviction of full queues runs in a second transaction after the commit (a failed eviction never fails the send; node-local,", new="(node-local,", tests=DOCS),
]
