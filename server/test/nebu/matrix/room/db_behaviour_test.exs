defmodule Nebu.Matrix.Room.DBBehaviourTest do
  use ExUnit.Case, async: true

  # ─── Story 5.29d AC1+AC2 (FB-E5-03): @behaviour Nebu.Matrix.Room.DBBehaviour ────────
  #
  # Purpose: compile-time conformance guard — ensures every module that implements
  # the Room DB interface declares `@behaviour Nebu.Matrix.Room.DBBehaviour`. When a new
  # callback is added to the behaviour or a fake drifts, the compiler will warn
  # (or error with strict settings) before tests run.
  #
  # RED-PHASE CONTRACT:
  #   These tests FAIL until:
  #     1. `Nebu.Matrix.Room.DBBehaviour` is defined with all required @callbacks.
  #     2. `Nebu.Matrix.Room.DB` declares `@behaviour Nebu.Matrix.Room.DBBehaviour`.
  #     3. `Nebu.Matrix.Room.InviteDB` — note: separate behaviour not required; InviteDB
  #        callbacks are in Nebu.Matrix.Room.InviteDBBehaviour (future story).
  #        For this story, only Nebu.Matrix.Room.DB is checked.
  #
  # The test-process check (module_behaviours assertions) is compile-time information
  # surfaced at runtime. Incorrect @behaviour declarations cause warnings; missing
  # callbacks cause warnings. We assert them explicitly here so CI counts this as
  # a failing test, not just a compiler warning.
  #
  # AC coverage:
  #   AC1 (FB-E5-03) — Nebu.Matrix.Room.DBBehaviour module exists
  #   AC2            — Nebu.Matrix.Room.DB implements Nebu.Matrix.Room.DBBehaviour

  # ─── AC1: Nebu.Matrix.Room.DBBehaviour module exists and has the required callbacks ───

  describe "Nebu.Matrix.Room.DBBehaviour — module and callback contract" do
    test "Nebu.Matrix.Room.DBBehaviour is defined as a module" do
      # FAILS until db_behaviour.ex is created.
      assert Code.ensure_loaded?(Nebu.Matrix.Room.DBBehaviour),
             "Nebu.Matrix.Room.DBBehaviour module not found — create core/apps/room_manager/lib/nebu/room/db_behaviour.ex"
    end

    test "Nebu.Matrix.Room.DBBehaviour defines the required callbacks" do
      # FAILS until db_behaviour.ex declares all @callback entries.
      callbacks = Nebu.Matrix.Room.DBBehaviour.behaviour_info(:callbacks)

      required = [
        {:load_members, 1},
        {:insert_room, 1},
        {:insert_member, 2},
        {:delete_member, 2},
        {:insert_event, 1},
        {:set_power_levels, 2},
        {:get_rooms_for_user, 1},
        {:get_recently_left_rooms_for_user, 1},
        {:fetch_events, 4},
        {:fetch_events_since, 3},
        {:get_event_timestamp, 1},
        {:get_room_name, 1},
        # Story 6.8: load_room_settings/1 callback for max_members recovery on restart.
        {:load_room_settings, 1},
        # Story 6.9: get_room_status/1 callback for archived room guard in init/1.
        {:get_room_status, 1},
        # Story 9-9: check_room_status_for_update/1 — SELECT FOR UPDATE TOCTOU fix.
        {:check_room_status_for_update, 1},
        # Story 11-8: fetch_event/2 — single-event lookup by (event_id, room_id).
        {:fetch_event, 2},
        # Story personal-self-room: personal room idempotency anchor.
        {:get_personal_room_id, 1},
        {:set_personal_room_id, 2},
        # Story direct-room-heroes: hero/member-count computation.
        {:get_room_heroes, 2},
        # Story admin-auto-join-rooms: auto-join enforcement at first login.
        {:list_auto_join_rooms, 0}
      ]

      for {fun, arity} <- required do
        assert {fun, arity} in callbacks,
               "Expected Nebu.Matrix.Room.DBBehaviour to declare @callback #{fun}/#{arity} but it was not found in #{inspect(callbacks)}"
      end
    end
  end

  # ─── AC2: Nebu.Matrix.Room.DB declares @behaviour Nebu.Matrix.Room.DBBehaviour ──────────────

  describe "Nebu.Matrix.Room.DB — behaviour declaration" do
    test "Nebu.Matrix.Room.DB declares @behaviour Nebu.Matrix.Room.DBBehaviour" do
      # FAILS until `@behaviour Nebu.Matrix.Room.DBBehaviour` is added to db.ex.
      behaviours = Nebu.Matrix.Room.DB.module_info(:attributes)[:behaviour] || []

      assert Nebu.Matrix.Room.DBBehaviour in behaviours,
             "Nebu.Matrix.Room.DB must declare `@behaviour Nebu.Matrix.Room.DBBehaviour`. " <>
               "Current behaviours: #{inspect(behaviours)}"
    end

    test "Nebu.Matrix.Room.DB exports all callbacks declared by Nebu.Matrix.Room.DBBehaviour" do
      # Belt-and-suspenders: verify the production module exports all required callbacks.
      # FAILS if Nebu.Matrix.Room.DB is missing any function listed in the behaviour.
      callbacks = Nebu.Matrix.Room.DBBehaviour.behaviour_info(:callbacks)
      db_exports = Nebu.Matrix.Room.DB.module_info(:exports)

      for {fun, arity} <- callbacks do
        assert {fun, arity} in db_exports,
               "Nebu.Matrix.Room.DB is missing function #{fun}/#{arity} required by Nebu.Matrix.Room.DBBehaviour"
      end
    end
  end
end
