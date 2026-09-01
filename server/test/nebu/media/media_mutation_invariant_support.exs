defmodule Nebu.Media.StateMachine.MutationInvariant do
  @moduledoc """
  Test-support helper for the `media-security-admin-control/1b-state-machine-module`
  story's grep-based invariant check (AC6).

  **This is defense-in-depth only, NOT the authoritative guarantee.** The
  authoritative enforcement that `media_state_transitions` cannot be silently
  rewritten — and therefore that `media_files.state` can only ever change
  through a row that is also recorded in that append-only ledger — is the
  DB-level `BEFORE UPDATE OR DELETE` trigger (`media_state_transitions_no_mutate`,
  raising SQLSTATE 23001) plus RLS/REVOKE added by Story 1a's migration
  (`000022_media_state_machine_foundation`, ADR-031). That trigger fires for
  every role, including the table owner, and is the only layer that also
  blocks a raw `psql` session or a future migration bug.

  This module is a cheap, fast, first line of defense that catches an
  accidental direct SQL `UPDATE ... media_files ... SET ... state` statement
  committed anywhere in `server/lib/` OTHER than
  `nebu/media/state_machine.ex` (the one module allowed to perform that
  UPDATE, always inside the same `Repo.transaction/1` as the
  `media_state_transitions` INSERT — see `Nebu.Media.StateMachine`). It runs
  as a plain ExUnit test under `make test-unit-elixir` (no DB required) so it
  fails fast in code review / CI, well before a bad statement could ever
  reach a real database and be blocked (or, in some misconfigured
  environment, NOT be blocked) by the trigger.

  A green result here is NOT proof that `media_state_transitions` is
  immutable, and must never be used as a reason to remove, weaken, or
  "simplify away" the Story 1a trigger/RLS — they protect different attack
  surfaces (committed application source vs. any raw SQL / DB-role access).

  Kept as a `.exs` file, `Code.require_file`'d from `test/test_helper.exs`
  (not compiled via `elixirc_paths`, which is `["lib"]` only per `mix.exs`),
  mirroring this project's existing test-support convention
  (`media_test_support.exs`, `media_fakes.exs`, `oidc_test_support.exs`)
  rather than introducing a new `test/support/` directory / `.ex` compiled
  path.
  """

  # Matches a direct `UPDATE ... media_files ... SET ... state = ...`
  # statement, tolerating an inline column list / whitespace / newlines
  # between `UPDATE media_files` and `SET`, and between `SET` and the
  # `state` assignment (e.g. `SET compressed = true, state = $2`). Does NOT
  # match unrelated `media_files` column updates (e.g. `SET compressed =
  # true` alone) because it requires the literal word `state` immediately
  # followed by `=` (optionally whitespace) somewhere after `SET`.
  #
  # code-review MAJOR fix (M3, test-review-findings.md): both spans (`UPDATE
  # media_files` -> `SET` and `SET` -> `state =`) are now bounded by a
  # negative lookahead that forbids crossing a `WHERE` keyword,
  # `(?:(?!\bWHERE\b)[\s\S]){0,200}?`, instead of a plain non-greedy
  # `[\s\S]{0,200}?`. The previous unbounded span let `state` be matched
  # anywhere after `SET`, including inside a later `WHERE` clause that
  # merely *references* `state` without assigning it — e.g.
  # `UPDATE media_files SET compressed = true WHERE state = 'released' AND
  # media_id = $1` is a legitimate update of an unrelated column, but the
  # old regex flagged it as a `state` mutation because its non-greedy match
  # was free to skip past the `WHERE` boundary looking for the substring
  # `state\s*=` (which it then found in the WHERE clause itself). Bounding
  # the span so it cannot contain a `WHERE` keyword forces `state` to be
  # matched only within the `SET` clause proper, while a real `SET ... state
  # = ...` assignment (with or without a trailing `WHERE`) still matches
  # because `state\s*=` is found before any `WHERE` is ever seen. Verified
  # directly against both the true-positive and false-positive fixtures
  # before landing this fix (see state_machine_invariant_test.exs).
  @violation_regex ~r/UPDATE\s+media_files\b(?:(?!\bWHERE\b)[\s\S]){0,200}?\bSET\b(?:(?!\bWHERE\b)[\s\S]){0,200}?\bstate\s*=/i

  # The one module allowed to issue this UPDATE (Nebu.Media.StateMachine,
  # Story 1b) — excluded from the scan. Matched by relative path (not bare
  # basename) so a future same-named file in a different domain (e.g.
  # `nebu/matrix/state_machine.ex`) is NOT silently exempted (code-review
  # MINOR fix, MIN-2, code-review-findings.md).
  @excluded_relative_path "nebu/media/state_machine.ex"

  @doc """
  Returns `true` if `source` (an in-memory string — a file's contents, or a
  fixture string in a test) contains the forbidden direct
  `UPDATE ... media_files ... SET ... state` pattern.

  Used directly (without touching the filesystem) by the invariant checker's
  own positive/negative-control tests (AC6 tests 13/14).
  """
  @spec violation?(String.t()) :: boolean()
  def violation?(source) when is_binary(source) do
    Regex.match?(@violation_regex, source)
  end

  @doc """
  Scans every `.ex` file under `lib_dir` (default: this project's
  `server/lib`) for the forbidden pattern, excluding
  `nebu/media/state_machine.ex` (matched by path relative to `lib_dir`, not
  bare basename).

  Returns the list of relative-to-`lib_dir` paths that violate the
  invariant (empty list == green). Used by the real-tree scan (AC6 test 12).
  """
  @spec scan(String.t()) :: [String.t()]
  def scan(lib_dir \\ default_lib_dir()) do
    lib_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&{&1, Path.relative_to(&1, lib_dir)})
    |> Enum.reject(fn {_path, relative} -> relative == @excluded_relative_path end)
    |> Enum.filter(fn {path, _relative} -> path |> File.read!() |> violation?() end)
    |> Enum.map(fn {_path, relative} -> relative end)
  end

  defp default_lib_dir do
    Path.join(File.cwd!(), "lib")
  end
end
