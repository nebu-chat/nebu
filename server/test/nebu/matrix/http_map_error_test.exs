defmodule Nebu.Matrix.HttpMapErrorTest do
  @moduledoc """
  Story `event-size-limit` (epic oauth-broker, follow-up `ep`), AC6 (D2 (e)): the command layer has no "too large" status today, so there is no path to a
  413 from `Nebu.Matrix.Http.call_core/1`. The story adds `Nebu.Matrix.Status.too_large/0` (`:too_large`) and one `map_error/1` clause:
  `{413, "M_TOO_LARGE", message || "Event exceeds the maximum size of 65536 bytes"}`; an `errcode` on the error is ignored (still `M_TOO_LARGE`).

  No existing suite pins `Http.map_error/1` as such (it is private; the other suites reach it through their routes), so this is a NEW suite (the story
  allows it: "or a new `http_map_error_test.exs` if none exists"): the new clause AND a table of the existing mappings as a regression pin
  ("every existing mapping unchanged"). Pure unit, `async: true`.
  """
  use ExUnit.Case, async: true

  alias Nebu.Matrix.Http

  @status Nebu.Matrix.Status

  defp status(fun), do: apply(@status, fun, [])

  defp mapped(opts), do: Http.call_core(fn -> raise Nebu.Matrix.Error, opts end)

  describe "AC6 - the new too_large status" do
    test "Nebu.Matrix.Status.too_large/0 returns :too_large" do
      assert status(:too_large) == :too_large
    end

    test "a raised :too_large with a message is {:error, {413, \"M_TOO_LARGE\", message}}" do
      assert mapped(status: :too_large, message: "M") == {:error, {413, "M_TOO_LARGE", "M"}}
    end

    test "the call_core shape of the story: a fun that raises Nebu.Matrix.Error with the :too_large status" do
      assert Http.call_core(fn -> raise Nebu.Matrix.Error, status: :too_large, message: "M" end) == {:error, {413, "M_TOO_LARGE", "M"}}
    end

    test "an errcode on the error is ignored: still M_TOO_LARGE" do
      assert mapped(status: :too_large, message: "M", errcode: "M_BAD_JSON") == {:error, {413, "M_TOO_LARGE", "M"}}
      assert mapped(status: :too_large, message: "M", errcode: "M_INVALID_PARAM") == {:error, {413, "M_TOO_LARGE", "M"}}
    end

    test "without a message the default text is the event limit" do
      assert mapped(status: :too_large, message: nil) == {:error, {413, "M_TOO_LARGE", "Event exceeds the maximum size of 65536 bytes"}}
    end

    test "the status function and the struct form agree" do
      assert Http.call_core(fn -> raise %Nebu.Matrix.Error{status: status(:too_large), message: "x"} end) == {:error, {413, "M_TOO_LARGE", "x"}}
    end
  end

  describe "AC6 - every existing mapping is unchanged (regression pin)" do
    test "the status table" do
      assert mapped(status: :not_found, message: "room not found: !x") == {:error, {404, "M_NOT_FOUND", "Room not found"}}
      assert mapped(status: :permission_denied, message: "x") == {:error, {403, "M_FORBIDDEN", "You are not a member of this room"}}
      assert mapped(status: :invalid_argument, message: nil) == {:error, {400, "M_INVALID_PARAM", "Invalid parameter"}}
      assert mapped(status: :invalid_argument, message: "bad") == {:error, {400, "M_INVALID_PARAM", "bad"}}
      assert mapped(status: :resource_exhausted, message: "x") == {:error, {403, "M_ROOM_FULL", "Room is full"}}
      assert mapped(status: :failed_precondition, message: nil) == {:error, {400, "M_BAD_STATE", "Bad state"}}
      assert mapped(status: :unavailable, message: "x") == {:error, {503, "M_UNAVAILABLE", "Core is temporarily unavailable"}}
      assert mapped(status: :unauthenticated, message: "x") == {:error, {401, "M_UNKNOWN_TOKEN", "Unauthenticated"}}
      assert mapped(status: :internal, message: "x") == {:error, {500, "M_UNKNOWN", "Internal server error"}}
    end

    test "the opt-in errcodes" do
      assert mapped(status: :invalid_argument, message: "m", errcode: "M_BAD_JSON") == {:error, {400, "M_BAD_JSON", "m"}}
      assert mapped(status: :permission_denied, message: "m", errcode: "M_FORBIDDEN") == {:error, {403, "M_FORBIDDEN", "m"}}
      assert mapped(status: :not_found, message: "m", errcode: "M_UNKNOWN_USER") == {:error, {404, "M_UNKNOWN_USER", "m"}}
      assert mapped(status: :unavailable, message: "m", errcode: "M_LIMIT_EXCEEDED") == {:error, {503, "M_LIMIT_EXCEEDED", "m"}}
    end

    test "an unknown status atom is the generic 500, never a 413" do
      assert mapped(status: :nonsense, message: "x") == {:error, {500, "M_UNKNOWN", "Internal server error"}}
    end

    test "a value is returned as {:ok, value}" do
      assert Http.call_core(fn -> :fine end) == {:ok, :fine}
    end
  end
end
