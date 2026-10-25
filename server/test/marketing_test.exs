defmodule HabibiWeb.MarketingTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  test "the release serves public marketing and assets without changing API privacy" do
    home = request("/")
    assert home.status == 200
    assert home.resp_body =~ "An agent of your own."
    assert get_resp_header(home, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(home, "cache-control") == ["public, max-age=300"]

    assert request("/assets/styles.css").status == 200
    assert request("/assets/theme.css").status == 200
    theme = request("/assets/theme.json")
    assert theme.status == 200
    assert get_resp_header(theme, "content-type") == ["application/json"]
    assert Jason.decode!(theme.resp_body) == Jason.decode!(File.read!("priv/theme.json"))
    assert get_resp_header(theme, "set-cookie") == []
    assert request("/robots.txt").resp_body =~ "https://habibi.fyi/sitemap.xml"
    assert request("/sitemap.xml").resp_body =~ "https://habibi.fyi/"

    health = request("/health")
    assert Jason.decode!(health.resp_body) == %{"status" => "ok"}
    assert get_resp_header(health, "cache-control") == ["no-store"]

    api_missing = request("/v1/not-found")
    assert api_missing.status == 404
    assert Jason.decode!(api_missing.resp_body) == %{"error" => "not_found"}
    assert get_resp_header(api_missing, "cache-control") == ["no-store"]

    for path <- [
          "/missing",
          "/missing/page",
          "/client/vault.mjs",
          "/marketing/site/index.njk",
          "/locales.json"
        ] do
      missing = request(path)
      assert missing.status == 404
      assert missing.resp_body =~ "Nothing here."
    end
  end

  defp request(path), do: conn(:get, path) |> HabibiWeb.Endpoint.call([])
end
