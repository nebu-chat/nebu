defmodule Nebu.Matrix.MembershipWriteLimitsCycle1DocsTest do
  @moduledoc """
  Static checks (no DB) for the docs and config of review cycle 1 of story `rate-limits-join-invite-create-room`:

    * the overstated "hard bound" wording is gone (Kassandra L-2): the caps are a cluster-wide count bound under advisory locks, the
      uncapped writers, the slot-filling residual, the sync byte budget and `ep` are named in the release notes and the gate;
    * `POST /rooms/{id}/upgrade` is documented as charged (Kassandra L-1, D14);
    * closed claims are not left inline in `ex`, `eo` and the scope-doc invite row (code review MINOR-3);
    * the follow-up `fj` (the pre-existing `tick/0` flake) and the `ep` note exist, the id line moved to `fk`;
    * `docker-compose.yml` passes the nine variables through (Kassandra INFO-4); the migration header has no dev-environment note.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @compose Path.join(@root, "docker-compose.yml")
  @migration Path.join(@root, "server/priv/migrations/000050_room_invitations_pending_inviter_idx.up.sql")

  @variables ~w(NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN NEBU_RATE_LIMIT_CREATE_ROOM_BURST NEBU_RATE_LIMIT_INVITE_PER_MIN NEBU_RATE_LIMIT_INVITE_BURST
                NEBU_RATE_LIMIT_JOIN_PER_MIN NEBU_RATE_LIMIT_JOIN_BURST NEBU_INVITE_MAX_PENDING_PER_INVITER NEBU_INVITE_MAX_PENDING_PER_INVITEE
                NEBU_INVITE_MAX_PENDING_PER_PAIR)

  defp flat(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp scope_row(prefix) do
    row = @scope |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, prefix))
    assert row, "no scope row #{prefix}"
    String.replace(row, ~r/\s+/, " ")
  end

  defp followup_cells(id) do
    line = @followups |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| #{id} | "))
    assert line, "the follow-up row #{id} does not exist"
    line |> String.replace(~r/\s+/, " ") |> String.trim_leading("| ") |> String.trim_trailing(" |") |> String.split(" | ")
  end

  defp gate_paragraph do
    raw = File.read!(@deploy)
    {at, _} = :binary.match(raw, "**RELEASE GATE")
    [para | _] = String.split(binary_part(raw, at, byte_size(raw) - at), "\n\n", parts: 2)
    String.replace(para, ~r/\s+/, " ")
  end

  test "07-deployment: no 'hard bound' claim; the caps are a cluster-wide count bound under advisory locks, uncapped writers are counted but never refused" do
    deploy = flat(@deploy)

    refute deploy =~ "the caps are the hard bound on what a victim sees"
    assert deploy =~ ~r/cluster-wide count bound/i
    assert deploy =~ ~r/advisory locks/i
    assert deploy =~ ~r/`upgrade_room` and the Admin force-add are counted but never refused/
  end

  test "07-deployment: the release notes name the slot-filling residual, the ignore / deactivation exclusion, the upgrade charge, the sync byte budget with ep, the SHARE lock of the index" do
    deploy = flat(@deploy)

    assert deploy =~ ~r/colluding accounts/i and deploy =~ "`fb`"
    assert deploy =~ "`m.ignored_user_list`" and deploy =~ ~r/deactivated inviter/i
    assert deploy =~ ~r/`POST \/rooms\/\{id\}\/upgrade` spends one `create_room` unit/
    assert deploy =~ "64 KiB" and deploy =~ "8 MiB" and deploy =~ "`ep`"
    assert deploy =~ "SHARE lock"
    refute deploy =~ "reset the throwaway test database after pulling it"
  end

  test "07-deployment: the RELEASE GATE paragraph names the residuals (fi (a)-(e), ep, the slot-filling note) next to fh and ex" do
    gate = gate_paragraph()

    assert gate =~ "`ep`" and gate =~ "`fi`" and gate =~ ~r/occupy a victim's 100 invitation slots/
    assert gate =~ "`fh`" and gate =~ "`ex`"
  end

  test "08-concepts and the scope doc: the upgrade route is charged, the caps are hard under concurrency, the invitee total excludes ignored / deactivated inviters, the sync byte budget" do
    concepts = flat(@concepts)
    assert concepts =~ ~r/`POST \/rooms\/\{id\}\/upgrade` spends one `create_room` unit/
    assert concepts =~ ~r/advisory locks/ and concepts =~ "64 KiB" and concepts =~ "8 MiB"

    upgrade = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/upgrade` |")
    assert upgrade =~ "`create_room`" and upgrade =~ "429"

    create = scope_row("| POST | `/_matrix/client/v3/createRoom` | ")
    assert create =~ ~r/Hard under concurrency/ and create =~ "insert_invitation_capped/4" and create =~ "`m.ignored_user_list`"

    sync = scope_row("| GET | `/_matrix/client/v3/sync` | ")
    assert sync =~ ~r/Byte budget/ and sync =~ "64 KiB" and sync =~ "8 MiB" and sync =~ "`ep`"
  end

  test "scope doc: the invite row points to fh (not fa) for M_INVITE_BLOCKED and the sentences are separated" do
    row = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/invite` |")

    assert row =~ "the v1.18 `M_INVITE_BLOCKED` is not implemented either (`fh`)."
    refute row =~ "not implemented either (`fa`)"
    assert row =~ "(follow-up `fb`). **Rate limit and caps"
  end

  test "follow-ups: closed claims are rewritten inline in ex and eo, and the ey closure says what L-3 really got" do
    [_, ex_text | _] = followup_cells("ex")
    refute ex_text =~ "`/join` has no rate limit"
    assert ex_text =~ "rate limited per user"

    [_, eo_text | _] = followup_cells("eo")
    refute eo_text =~ "createRoom has no rate limit"
    assert eo_text =~ "rate limited per user"

    [_, ey_text | _] = followup_cells("ey")
    refute ey_text =~ "Kassandra L-3 closed)"
    assert ey_text =~ "BYTE budget" and ey_text =~ "`ep`"
  end

  test "follow-ups: fj records the pre-existing tick() flake with its fix, ep says it is the next story, fi carries the review-cycle-1 facts, the id line ends at fj" do
    [_, fj_text, origin, status] = followup_cells("fj")
    assert fj_text =~ "tick/0" and fj_text =~ "room_summary_integration_test" and fj_text =~ "matrix_client_compat_test" and fj_text =~ "origin_server_ts <="
    assert origin =~ "rate-limits-join-invite-create-room" and String.downcase(status) =~ "open"

    [_, ep_text | _] = followup_cells("ep")
    assert ep_text =~ "NEXT story"

    [_, fi_text | _] = followup_cells("fi")
    for word <- ["HARD", "advisory locks", "slot filling", "colluding", "docker-compose.yml", "tofu", "stop-gap"], do: assert(fi_text =~ word, "fi mentions #{word}")

    f = flat(@followups)
    assert f =~ "`fh`-`fj`: rate-limits-join-invite-create-room"
    # story member-event-prev-content (DELIBERATE re-pin, AC9 (b); old -> new): `fk` - `fl` are used by that story, the unused ids continue at `fn` (review cycle 1 of the same story added `fm`) ("`fk` onward" before)
    # story event-size-limit (DELIBERATE re-pin, AC9 (b); old -> new): `fn` - `fp` are used by that story, the unused ids continue at `fq` ("`fn` onward" before)
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): `fq` - `fr` are used by that story, the unused ids continue at `fs` ("`fq` onward" before)
    # moderation-routes-atomic-ban review cycles 1 / 2 (DELIBERATE re-pin): `fs`-`fu` are used, unused ids continue at `fv`
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fv`-`fz` are used by that story, the unused ids continue at `ga` ("`fv` onward" before)
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/
  end

  test "docker-compose.yml passes the nine variables through with an empty default" do
    compose = File.read!(@compose)

    for variable <- @variables do
      assert compose =~ ~s(#{variable}: "${#{variable}:-}"), "#{variable} is passed through"
    end
  end

  test "the migration header carries no dev-environment note" do
    header = File.read!(@migration) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
    refute header =~ ~r/throwaway/i
    assert header =~ "SHARE lock"
  end

  # ── delta gate (Kassandra H-1, L-1, L-2, L-3, I-1, I-8) ─────────────────────────

  test "07-deployment and 08-concepts: the optional stripped state is bounded, create and member content stays unbounded until ep; PostgreSQL 16+ is named" do
    for doc <- [flat(@deploy), flat(@concepts)] do
      assert doc =~ ~r/optional stripped state is bounded/i
      assert doc =~ ~r/create and member content stays unbounded until `ep`|`m\.room\.create` above 64 KiB is reduced/i
    end

    deploy = flat(@deploy)
    assert deploy =~ "PostgreSQL 16+" and deploy =~ "pg_input_is_valid"
    assert deploy =~ ~r/lock_timeout|2 seconds/ and deploy =~ "M_LIMIT_EXCEEDED"
  end

  test "the story: D7 no longer says the ignore list does not change the counting (it points to D16 (a)), D18 says what stays unbounded" do
    story = flat(Path.join(@root, "docs/stories/oauth-broker/rate-limits-join-invite-create-room.md"))

    refute story =~ "**The ignore list** does not change the counting"
    assert story =~ ~r/The ignore list[^.]*D16 \(a\)/
    assert story =~ ~r/create and member content stays unbounded until `ep`/
  end

  test "the delta-gate source pins: the real InviteDB is never served by the fallback, the capped transaction sets lock_timeout, the ignore list is parsed in a lateral join" do
    root = Path.join(@root, "server/lib/nebu/matrix")
    server = File.read!(Path.join(root, "event_dispatcher/server.ex"))
    invite_db = File.read!(Path.join(root, "room/invite_db.ex"))

    assert server =~ "mod == Nebu.Matrix.Room.InviteDB or"
    assert invite_db =~ "SET LOCAL lock_timeout = '2s'"
    assert invite_db =~ "LEFT JOIN LATERAL"
    refute invite_db =~ ~r/NOT EXISTS \(SELECT 1 FROM account_data/, "no per-row subquery over the ignore list"
  end
end
