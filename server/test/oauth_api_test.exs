defmodule Habibi.OAuthAPITest do
  use ExUnit.Case, async: false
  import Habibi.AuthTestHelpers
  import Plug.Conn
  import Plug.Test
  alias Habibi.Repo

  setup context do
    if context[:unboxed] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    else
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    end

    stub_subscription()
    :ok
  end

  test "capabilities publicly describe the current deployment without accepting request overrides" do
    previous = Application.fetch_env!(:habibi, :allow_registration)
    on_exit(fn -> Application.put_env(:habibi, :allow_registration, previous) end)

    for registration <- [true, false] do
      Application.put_env(:habibi, :allow_registration, registration)

      expected = %{
        "version" => 1,
        "authentication" => %{
          "passkeys" => true,
          "phone" => false,
          "accountRegistration" => registration
        },
        "oauth" => %{"dynamicClientRegistration" => registration},
        "subscriptions" => %{
          "available" => true,
          "entitlement" => "plus",
          "products" => ["habibi_plus_monthly", "habibi_plus_yearly"],
          "requiredFor" => ["syncWrites", "draftHandoff"]
        },
        "sync" => %{
          "encryptedSnapshots" => true,
          "vaultCreation" => registration,
          "locks" => %{
            "version" => 1,
            "leaseSeconds" => 30,
            "maxPerVault" => 32,
            "fencedRecordPut" => true
          }
        },
        "themes" => %{"catalog" => "/assets/themes.json"}
      }

      response = request(:get, "/v1/capabilities")
      assert response.status == 200
      assert body(response) == expected
      assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "set-cookie") == []

      assert request(:get, "/v1/capabilities?phone=true&catalog=https%3A%2F%2Fevil.example")
             |> body() == expected
    end
  end

  test "discovery and registration expose only the public native profile" do
    metadata = request(:get, "/.well-known/oauth-authorization-server") |> body()
    assert metadata["code_challenge_methods_supported"] == ["S256"]
    assert metadata["token_endpoint_auth_methods_supported"] == ["none"]
    assert metadata["registration_endpoint"] == Habibi.OAuth.issuer() <> "/oauth/register"
    assert metadata["grant_types_supported"] == ["authorization_code", "refresh_token"]
    client = register_client()
    refute Map.has_key?(client, "client_secret")
    assert client["redirect_uris"] == ["fyi.habibi.test:/oauth/callback"]

    for redirect <- [
          "http://app.example/cb",
          "https://app.example/*",
          "https://user@app.example/cb",
          "https://app.example/cb#fragment",
          "https://app.example/cb?query=1",
          "https://app.example:bad/cb",
          "https://app.example/cb\t",
          "javascript:/callback",
          "fyi.habibi.test://host/cb"
        ] do
      params = %{
        "client_name" => "App",
        "redirect_uris" => [redirect],
        "token_endpoint_auth_method" => "none"
      }

      assert request(:post, "/oauth/register", params).status == 400
    end

    for override <- [
          %{"jwks_uri" => "http://127.0.0.1/private"},
          %{"pkce" => false},
          %{"grant_types" => ["password"]},
          %{"scope" => "openid"}
        ] do
      params =
        Map.merge(
          %{
            "client_name" => "App",
            "redirect_uris" => ["https://app.example/cb"],
            "token_endpoint_auth_method" => "none"
          },
          override
        )

      assert request(:post, "/oauth/register", params).status == 400
    end
  end

  test "authorization requires S256, an exact redirect and an immutable browser consent" do
    client = register_client(%{"client_name" => "<script>untrusted</script>"})
    {params, _} = authorization(client)
    page = request(:get, "/oauth/authorize?" <> URI.encode_query(params))
    assert page.status == 200
    assert page.resp_body =~ "&lt;script&gt;untrusted&lt;/script&gt;"
    refute page.resp_body =~ "Allow connection"
    assert get_resp_header(page, "cache-control") == ["no-store"]

    for override <- [
          %{"code_challenge_method" => "plain"},
          %{"code_challenge_method" => ""},
          %{"redirect_uri" => "fyi.habibi.test:/oauth/other"},
          %{"scope" => "openid"},
          %{"request_uri" => "http://127.0.0.1/private"},
          %{"request" => "jwt"}
        ] do
      assert request(:get, "/oauth/authorize?" <> URI.encode_query(Map.merge(params, override))).status ==
               400
    end

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      request(:post, "/oauth/authorize", %{"decision" => "allow"})
    end
  end

  test "browser locale falls back to installed English without changing OAuth policy or errors" do
    client = register_client()
    {params, _} = authorization(client)
    path = "/oauth/authorize?" <> URI.encode_query(params)
    previous = Gettext.get_locale(HabibiWeb.AuthGettext)
    Gettext.put_locale(HabibiWeb.AuthGettext, "uninstalled")
    on_exit(fn -> Gettext.put_locale(HabibiWeb.AuthGettext, previous) end)

    for language <- ["ar, en-US;q=0.8", "fr", "en;q=0", "\" onload=alert(1)", "en;q=NaN"] do
      page = request(:get, path, nil, [{"accept-language", language}])
      assert page.status == 200
      assert page.resp_body =~ ~s(<html lang="en" dir="ltr">)
      assert get_resp_header(page, "content-language") == ["en"]
      assert page.resp_body =~ ~s(class="button-primary" data-passkey="login")

      assert page.resp_body =~
               ~r{href="/assets/theme.css".*href="/auth-assets/auth.css"}s

      for {attribute, message} <- [
            {"prompt", "Follow your device’s passkey prompt…"},
            {"unsupported",
             "This browser does not support passkeys. Open this page in your system browser."},
            {"cancelled", "Passkey request cancelled. You can try again."},
            {"failure", "Sign-in could not be completed. Please try again."}
          ] do
        assert page.resp_body =~ ~s(data-#{attribute}="#{message}")
      end

      assert get_session(page, :authorization) |> Map.delete("created_at") == params
      assert Gettext.get_locale(HabibiWeb.AuthGettext) == "uninstalled"
    end

    for extra <- ["locale", "lang"] do
      invalid = Map.put(params, extra, "en")

      response =
        request(:get, "/oauth/authorize?" <> URI.encode_query(invalid), nil, [
          {"accept-language", "ar"}
        ])

      assert response.status == 400
      assert body(response) == %{"error" => "invalid_request"}
    end

    response =
      request(:post, "/oauth/token", %{"grant_type" => "password"}, [{"accept-language", "ar"}])

    assert response.status == 400
    assert body(response) == %{"error" => "unsupported_grant_type"}
  end

  test "code exchange, refresh and replay invalidate the complete grant, without storing bearer secrets" do
    {exchange, account} =
      authorize_client(register_client(), %{
        "client_id" => Ecto.UUID.generate(),
        "redirect_uri" => "https://evil.example/cb",
        "scope" => "openid"
      })

    first = request(:post, "/oauth/token", exchange) |> successful_token()
    assert first["expires_in"] in 899..900
    assert first["scope"] == "vaults:sync"
    assert body(me(first))["sub"] == account.id

    assert request(:get, "/v1/me", nil, [{"authorization", "bearer " <> first["access_token"]}]).status ==
             200

    rows =
      Ecto.Adapters.SQL.query!(Repo, "SELECT value, refresh_token FROM oauth_tokens", []).rows

    refute Enum.any?(rows, fn row ->
             exchange["code"] in row or first["access_token"] in row or
               first["refresh_token"] in row
           end)

    assert request(
             :post,
             "/oauth/token",
             Map.put(exchange, "code_verifier", String.duplicate("z", 43))
           ).status == 400

    assert request(
             :post,
             "/oauth/token",
             Map.put(exchange, "redirect_uri", "fyi.habibi.test:/wrong")
           ).status == 400

    assert me(first).status == 200

    refreshed = request(:post, "/oauth/token", refresh(exchange, first)) |> successful_token()
    refute refreshed["refresh_token"] == first["refresh_token"]
    assert me(refreshed).status == 200
    assert request(:post, "/oauth/token", refresh(exchange, first)).status == 400
    assert me(first).status == 401
    assert me(refreshed).status == 401
    assert request(:post, "/oauth/token", refresh(exchange, refreshed)).status == 400

    {other_exchange, _} = authorize_client()
    other = request(:post, "/oauth/token", other_exchange) |> successful_token()
    assert request(:post, "/oauth/token", other_exchange).status == 400
    assert me(other).status == 401
  end

  test "revocation is client-bound and revokes descendants; unsupported request objects cannot bypass policy" do
    {exchange, _} = authorize_client()
    first = request(:post, "/oauth/token", exchange) |> successful_token()
    successor = request(:post, "/oauth/token", refresh(exchange, first)) |> successful_token()
    stranger = register_client()

    assert request(:post, "/oauth/revoke", %{
             "client_id" => stranger["client_id"],
             "token" => first["refresh_token"]
           }).status == 200

    assert me(successor).status == 200

    assert request(
             :post,
             "/oauth/token",
             Map.put(refresh(exchange, successor), "request_uri", "http://127.0.0.1/private")
           ).status == 400

    assert request(:post, "/oauth/revoke?request=jwt", %{
             "client_id" => exchange["client_id"],
             "token" => first["access_token"]
           }).status == 400

    assert request(:post, "/oauth/token", Map.put(exchange, "client_id", stranger["client_id"])).status ==
             400

    assert me(successor).status == 200

    assert request(:post, "/oauth/revoke", %{
             "client_id" => exchange["client_id"],
             "token" => first["refresh_token"]
           }).status == 200

    assert me(successor).status == 401

    assert request(:post, "/oauth/revoke", %{
             "client_id" => exchange["client_id"],
             "token" => "unknown"
           }).status == 200
  end

  test "OAuth and vault capabilities are independent requirements, not account ownership" do
    first = access_token()
    second = access_token()

    vault = %{
      id: Ecto.UUID.generate(),
      token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    }

    creation =
      conn(:post, "/v1/vaults", Jason.encode!(vault))
      |> put_req_header("content-type", "application/json")

    assert endpoint(creation).status == 401

    assert creation
           |> put_req_header("authorization", "Bearer " <> first)
           |> endpoint()
           |> Map.fetch!(:status) == 201

    path = "/v1/vaults/#{vault.id}/records"
    assert request(:get, path, nil, [{"x-habibi-vault-token", vault.token}]).status == 401
    assert request(:get, path, nil, [{"authorization", "Bearer " <> first}]).status == 401

    assert request(:get, path, nil, [
             {"authorization", "Bearer " <> second},
             {"x-habibi-vault-token", vault.token}
           ]).status == 200
  end

  test "closed registration preserves OAuth metadata, existing authorization and authenticated sync" do
    client = register_client()
    {exchange, _} = authorize_client(client)
    tokens = request(:post, "/oauth/token", exchange) |> successful_token()
    authorization = [{"authorization", "Bearer " <> tokens["access_token"]}]

    vault = %{
      "id" => Ecto.UUID.generate(),
      "token" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    }

    assert request(:post, "/v1/vaults", vault, authorization).status == 201
    metadata = request(:get, "/.well-known/oauth-authorization-server") |> body()

    previous = Application.fetch_env!(:habibi, :allow_registration)
    Application.put_env(:habibi, :allow_registration, false)
    on_exit(fn -> Application.put_env(:habibi, :allow_registration, previous) end)

    assert body(request(:get, "/v1/capabilities"))["sync"] == %{
             "encryptedSnapshots" => true,
             "vaultCreation" => false,
             "locks" => %{
               "version" => 1,
               "leaseSeconds" => 30,
               "maxPerVault" => 32,
               "fencedRecordPut" => true
             }
           }

    assert request(:get, "/.well-known/oauth-authorization-server") |> body() == metadata

    for {path, params, headers} <- [
          {"/oauth/register", %{"client_name" => "Closed"}, []},
          {"/v1/vaults", vault, authorization}
        ] do
      response = request(:post, path, params, headers)
      assert response.status == 403
      assert body(response) == %{"error" => "registration_disabled"}
    end

    assert request(:post, "/v1/vaults", vault).status == 401

    {existing_exchange, _} = authorize_client(client)
    assert request(:post, "/oauth/token", existing_exchange).status == 200
    refreshed = request(:post, "/oauth/token", refresh(exchange, tokens)) |> successful_token()
    assert me(refreshed).status == 200

    path = "/v1/vaults/#{vault["id"]}/records"
    headers = [{"x-habibi-vault-token", vault["token"]} | authorization]
    id = Ecto.UUID.generate()
    ciphertext = "HAB1" <> :crypto.strong_rand_bytes(73)

    uploaded =
      conn(:put, path <> "/" <> id, ciphertext)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
      |> put_req_header("x-habibi-vault-token", vault["token"])
      |> endpoint()

    assert uploaded.status == 201
    assert body(request(:get, path, nil, headers))["records"] |> hd() |> Map.fetch!("id") == id
    assert request(:get, path <> "/" <> id, nil, headers).resp_body == ciphertext
    assert request(:get, path, nil, authorization).status == 401
    assert request(:get, path, nil, [{"x-habibi-vault-token", vault["token"]}]).status == 401
  end

  test "code-only clients receive no refresh token and grants have an absolute lifetime" do
    client = register_client(%{"grant_types" => ["authorization_code"]})
    {exchange, _} = authorize_client(client)
    tokens = request(:post, "/oauth/token", exchange) |> successful_token()
    refute Map.has_key?(tokens, "refresh_token")

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE oauth_grants SET expires_at = '2000-01-01 00:00:00'",
      []
    )

    assert me(tokens).status == 401
  end

  @tag :unboxed
  test "simultaneous code and refresh submissions use separate connections and only one succeeds" do
    {exchange, account} = authorize_client()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM oauth_grants WHERE id IN (SELECT grant_id FROM oauth_tokens WHERE client_id = $1)",
          [Ecto.UUID.dump!(exchange["client_id"])]
        )

        Repo.delete!(Repo.get!(Boruta.Ecto.Client, exchange["client_id"]))

        Repo.delete!(account)
        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM auth_rate_limits", [])
      end)
    end)

    results = race(exchange)
    assert Enum.sort(Enum.map(results, & &1.status)) == [200, 400]
    winner = Enum.find(results, &(&1.status == 200)) |> body()
    assert me(winner).status == 401

    # A fresh authorization uses the same client, but has an independent grant.
    {new_exchange, other_account} =
      authorize_client(%{
        "client_id" => exchange["client_id"],
        "redirect_uris" => [exchange["redirect_uri"]]
      })

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Repo.delete!(other_account) end)
    end)

    tokens = request(:post, "/oauth/token", new_exchange) |> successful_token()
    results = race(refresh(new_exchange, tokens))
    assert Enum.sort(Enum.map(results, & &1.status)) == [200, 400]

    assert results |> Enum.find(&(&1.status == 200)) |> body() |> me() |> Map.fetch!(:status) ==
             401
  end

  defp race(params) do
    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            receive do
              :go -> request(:post, "/oauth/token", params)
            end
          end)
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp successful_token(conn) do
    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp refresh(exchange, tokens),
    do: %{
      "grant_type" => "refresh_token",
      "client_id" => exchange["client_id"],
      "refresh_token" => tokens["refresh_token"]
    }

  defp me(tokens),
    do: request(:get, "/v1/me", nil, [{"authorization", "Bearer " <> tokens["access_token"]}])
end
