defmodule HabibiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :habibi

  plug Plug.RequestId
  plug Plug.Head

  plug Plug.Static,
    at: "/",
    from: {:habibi, "priv/static/marketing"},
    only: ~w(assets robots.txt sitemap.xml)

  plug :private_response

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/octet-stream"],
    json_decoder: Jason,
    length: 8192

  plug HabibiWeb.Router

  defp private_response(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
  end
end

defmodule HabibiWeb.Errors do
  def render(_template, _assigns), do: %{error: "request_failed"}
end
