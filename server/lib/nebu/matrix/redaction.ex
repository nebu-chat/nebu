defmodule Nebu.Matrix.Redaction do
  @moduledoc """
  Pure functions of the redaction read path (story state-writer-redaction, D5, D6). No database, no process, no state.

  A redaction is DERIVED at read time: the stored target row is never changed (Compliance Mode: the content stays
  server-readable, "Remove" hides a message, it does not erase it). The rows come from `Room.DB.redactions_for/1` (string keys
  `event_id`, `room_id`, `sender`, `origin_server_ts`, `content`, `redacts`; only writer-made redactions have a `redacts` value):

    * `index/1` turns them into the lookup of one response (the EARLIEST redaction per target, by `(origin_server_ts, event_id)`);
    * `served/1` renders one stored redaction as the event a client receives (`redacted_because`);
    * `served_content/2` is the ONE rule for the content of a served redaction event: a writer-made one carries
      `content.redacts` (v11 compatibility) next to its top-level `redacts`; a legacy row (`redacts` NULL, written unchecked
      through /send before this story, follow-up `gd`) is never applied and served without either, its stored key dropped;
    * `prune/2` applies a redaction to the event map of its target: `content` becomes `%{}`, `redacted_because` is attached.

  Every read path that serves event content goes through this module (a future `/context`, the search context and a rendered
  thread `latest_event` too, follow-up `fk`).
  """

  @type row :: %{optional(String.t()) => term()}
  @type index :: %{targets: %{String.t() => row()}, by_id: %{String.t() => row()}}

  @doc "The writer-made redaction rows as a lookup: `%{targets: %{target_id => earliest row}, by_id: %{redaction_event_id => row}}`."
  @spec index([row()]) :: index()
  def index(rows) do
    writer_rows = Enum.filter(rows, &is_binary(&1["redacts"]))

    targets =
      writer_rows
      |> Enum.sort_by(&{&1["origin_server_ts"], &1["event_id"]})
      |> Enum.reduce(%{}, fn row, acc -> Map.put_new(acc, row["redacts"], row) end)

    %{targets: targets, by_id: Map.new(writer_rows, &{&1["event_id"], &1})}
  end

  @doc """
  The redaction event as a client receives it (`unsigned.redacted_because` of its target): `event_id`, `type`, `room_id`,
  `sender`, `origin_server_ts`, the content of `served_content/2` and, for a writer-made row, the top-level `redacts`. No
  `unsigned`, nothing of the target.
  """
  @spec served(row()) :: map()
  def served(row) do
    {content, redacts} = served_content(row["content"], row["redacts"])

    event = %{
      "event_id" => row["event_id"],
      "type" => "m.room.redaction",
      "room_id" => row["room_id"],
      "sender" => row["sender"],
      "origin_server_ts" => row["origin_server_ts"],
      "content" => content
    }

    if redacts, do: Map.put(event, "redacts", redacts), else: event
  end

  @doc """
  The served content of a redaction event and its top-level `redacts` (`nil` for a legacy row): the stored content (an object,
  its JSON text, else `%{}`) without a stored `redacts` key, plus `"redacts" => target` when the writer stored the target
  (the column wins over any client key).
  """
  @spec served_content(term(), String.t() | nil) :: {map(), String.t() | nil}
  def served_content(stored_content, target) do
    content = stored_content |> content_map() |> Map.delete("redacts")

    if is_binary(target), do: {Map.put(content, "redacts", target), target}, else: {content, nil}
  end

  @doc "Prunes the event map of a redacted target: `content` becomes `%{}` and the served redaction is attached as `redacted_because`."
  @spec prune(map(), row() | nil) :: map()
  def prune(event, nil), do: event
  def prune(event, redaction_row), do: Map.merge(event, %{"content" => %{}, "redacted_because" => served(redaction_row)})

  @doc "A stored content as a map: an object, the JSON text of one (also double encoded), anything else is `%{}`."
  @spec content_map(term()) :: map()
  def content_map(content) when is_map(content), do: content

  def content_map(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} when is_binary(decoded) -> content_map(decoded)
      _ -> %{}
    end
  end

  def content_map(_content), do: %{}
end
