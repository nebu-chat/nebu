defmodule Nebu.Web.Plugs.RequestId do
  @moduledoc false
  @behaviour Plug

  @header "x-request-id"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    request_id =
      case Plug.Conn.get_req_header(conn, @header) do
        [id | _] when byte_size(id) > 0 -> id
        _ -> generate_uuid4()
      end

    conn
    |> Plug.Conn.put_req_header(@header, request_id)
    |> Plug.Conn.put_resp_header(@header, request_id)
  end

  defp generate_uuid4 do
    <<u0::32, u1::16, _::4, u2::12, _::2, u3::62>> = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, c::16, d::16, e::48>> = <<u0::32, u1::16, 4::4, u2::12, 2::2, u3::62>>

    [
      Integer.to_string(a, 16) |> String.pad_leading(8, "0"),
      Integer.to_string(b, 16) |> String.pad_leading(4, "0"),
      Integer.to_string(c, 16) |> String.pad_leading(4, "0"),
      Integer.to_string(d, 16) |> String.pad_leading(4, "0"),
      Integer.to_string(e, 16) |> String.pad_leading(12, "0")
    ]
    |> Enum.join("-")
    |> String.downcase()
  end
end
