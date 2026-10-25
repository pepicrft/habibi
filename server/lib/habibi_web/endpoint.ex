defmodule HabibiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :habibi

  plug Plug.RequestId
  plug Plug.Head

  plug Plug.Static, at: "/auth-assets", from: {:habibi, "priv/static/auth"}

  plug Plug.Static,
    at: "/",
    from: {:habibi, "priv/static/marketing"},
    only: ~w(assets robots.txt sitemap.xml)

  plug :private_response

  plug Plug.Session,
    store: :cookie,
    key: "_habibi_auth",
    signing_salt: "habibi-browser-v1",
    encryption_salt: "habibi-browser-encrypted-v1",
    secure: Application.compile_env!(:habibi, :secure_cookies),
    http_only: true,
    same_site: "Lax",
    max_age: 900

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
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
