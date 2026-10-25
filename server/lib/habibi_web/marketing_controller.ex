defmodule HabibiWeb.MarketingController do
  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  def home(conn, params) do
    page(conn, params, "", "index.html")
  end

  def changelog(conn, params) do
    page(conn, params, "changelog/", "changelog/index.html")
  end

  defp page(conn, params, path, file) do
    locale = params["locale"] || "en"

    if locale in locales() do
      canonical = if locale == "en", do: "/#{path}", else: "/#{locale}/#{path}"

      if conn.request_path == canonical do
        serve(conn, locale, file, 200)
      else
        conn |> put_status(301) |> redirect(to: canonical)
      end
    else
      not_found(conn, params)
    end
  end

  def not_found(%{path_info: ["v1" | _]} = conn, _params) do
    conn |> put_status(404) |> json(%{error: "not_found"})
  end

  def not_found(conn, _params) do
    locale = List.first(conn.path_info)
    locale = if locale in locales(), do: locale, else: "en"
    serve(conn, locale, "404.html", 404)
  end

  defp serve(conn, locale, file, status) do
    prefix = if locale == "en", do: "", else: locale

    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_content_type("text/html")
    |> send_file(status, Path.join([static_root(), prefix, file]))
  end

  defp locales do
    static_root() |> Path.join("locales.json") |> File.read!() |> Jason.decode!()
  end

  defp static_root, do: Application.app_dir(:habibi, "priv/static/marketing")
end
