defmodule Nebu.Matrix.EventDispatcher.AuditWriterSeamRaceRegressionTest do
  use ExUnit.Case, async: false

  # ─── Regression guard: the :compliance, :audit_writer Application env key ──────
  #
  # `:compliance, :audit_writer` is a process-GLOBAL Application env key. Several
  # test modules inject a fake/spy writer by writing it via
  # `Application.put_env(:compliance, :audit_writer, ...)` and clearing it in
  # `on_exit` with `Application.delete_env/2`. Production reads the same key once
  # per call at `Nebu.Matrix.EventDispatcher.Server` (set ONCE at boot in
  # config/test.exs) — so there is no production race; the hazard is purely
  # test-to-test.
  #
  # Bug history (this regression): `write_audit_log_test.exs` and
  # `user_deletion_test.exs` were both `async: true` and both wrote/deleted this
  # shared key. When their setup/on_exit callbacks interleaved, one module's
  # `on_exit` deleted the key mid-flight of the other, so `Server.write_audit_log/2`
  # fell through to the real `Nebu.Compliance.AuditWriter` and `assert_receive`
  # timed out — a seed-dependent flake.
  #
  # The correct, convention-matching fix is to declare every module that touches
  # this global key `async: false` (22 of 24 such modules already do). This guard
  # enforces that invariant structurally: it scans the test tree and fails listing
  # any module that injects the key without `async: false`, so a future `async: true`
  # module cannot silently reintroduce the race.
  #
  # async: false — this module itself is part of the invariant it enforces.

  # __DIR__ = server/test/nebu/matrix/event_dispatcher → three levels up = server/test
  @test_root Path.expand("../../../", __DIR__)

  test "every test module touching :compliance, :audit_writer declares async: false" do
    violators =
      Path.wildcard(Path.join(@test_root, "**/*.exs"))
      |> Enum.filter(fn path ->
        content = File.read!(path)
        # Only modules that actually INJECT the writer (put/delete), not ones that
        # merely mention the key in a comment.
        String.contains?(content, "put_env(:compliance, :audit_writer") or
          String.contains?(content, "delete_env(:compliance, :audit_writer")
      end)
      |> Enum.reject(fn path -> String.contains?(File.read!(path), "async: false") end)
      |> Enum.map(&Path.relative_to(&1, @test_root))
      |> Enum.sort()

    assert violators == [],
           """
           REGRESSION: the following test module(s) inject the global \
           :compliance, :audit_writer env but are NOT declared `async: false`. \
           Concurrent on_exit callbacks will clobber the audit_writer seam \
           mid-flight, reintroducing the WriteAuditLog flake:

           #{Enum.map_join(violators, "\n", &"  #{&1}")}

           Fix: change `use ExUnit.Case, async: true` to `async: false` in each \
           listed module (with a comment: shared global :compliance env key).
           """
  end
end
