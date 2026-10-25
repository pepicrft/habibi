defmodule HabibiWeb.ChangelogTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  test "the changelog is public, cacheable and does not start an auth session" do
    page = request("/changelog/")

    assert page.status == 200
    assert page.resp_body =~ "<h1>Changelog</h1>"
    assert page.resp_body =~ "Habibi 0.1.1"
    assert page.resp_body =~ "releases/tag/server%400.1.0"
    assert page.resp_body =~ "These are not mobile app releases"
    assert get_resp_header(page, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(page, "cache-control") == ["public, max-age=300"]
    assert get_resp_header(page, "set-cookie") == []

    head = request("/changelog/", :head)
    assert head.status == 200
    assert head.resp_body == ""
    assert get_resp_header(head, "cache-control") == ["public, max-age=300"]

    stylesheet = request("/assets/changelog.css")
    assert stylesheet.status == 200
    assert stylesheet.resp_body =~ ".changelog-timeline"
    assert get_resp_header(stylesheet, "set-cookie") == []
    assert request("/sitemap.xml").resp_body =~ "https://habibi.fyi/changelog/"
    assert request("/").resp_body =~ ~s(href="/changelog/")
  end

  test "English aliases redirect to the trailing-slash canonical URL" do
    for path <- ["/changelog", "/en/changelog", "/en/changelog/"] do
      response = request(path)
      assert response.status == 301
      assert get_resp_header(response, "location") == ["/changelog/"]
      assert get_resp_header(response, "set-cookie") == []
    end
  end

  test "every built locale uses the localized canonical changelog path" do
    locales =
      Application.app_dir(:habibi, "priv/static/marketing/locales.json")
      |> File.read!()
      |> Jason.decode!()

    for locale <- locales do
      prefix = if locale == "en", do: "/", else: "/#{locale}/"
      response = request(prefix <> "changelog/")
      assert response.status == 200
      assert response.resp_body =~ ~s(href="https://habibi.fyi#{prefix}changelog/")
      assert get_resp_header(response, "cache-control") == ["public, max-age=300"]

      redirect = request(prefix <> "changelog")
      assert redirect.status == 301
      assert get_resp_header(redirect, "location") == [prefix <> "changelog/"]
    end
  end

  test "unknown locales and paths remain 404s and API responses remain private" do
    for path <- ["/unknown/changelog/", "/changelog/missing", "/changelog.json"] do
      missing = request(path)
      assert missing.status == 404
      assert missing.resp_body =~ "Nothing here."
    end

    missing_api = request("/v1/changelog")
    assert missing_api.status == 404
    assert Jason.decode!(missing_api.resp_body) == %{"error" => "not_found"}
    assert get_resp_header(missing_api, "cache-control") == ["no-store"]

    metadata = request("/.well-known/oauth-authorization-server")
    assert metadata.status == 200
    assert get_resp_header(metadata, "cache-control") == ["no-store"]
  end

  defp request(path, method \\ :get), do: conn(method, path) |> HabibiWeb.Endpoint.call([])
end
