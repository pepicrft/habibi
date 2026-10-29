ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Habibi.Repo, :manual)

defmodule Habibi.TestStorage do
  def put(key, bytes) do
    if callback = Process.get(:storage_put_callback), do: callback.()

    if Process.get(:storage_unavailable) do
      {:error, :storage_unavailable}
    else
      Process.put({__MODULE__, key}, bytes)
      :ok
    end
  end

  def get(key) do
    case Process.get({__MODULE__, key}) do
      nil -> {:error, :storage_unavailable}
      bytes -> {:ok, bytes}
    end
  end
end

defmodule Habibi.AuthTestHelpers do
  import ExUnit.Assertions
  import Plug.Conn
  import Plug.Test

  def register_client(overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "client_name" => "Native test app",
          "redirect_uris" => ["fyi.habibi.test:/oauth/callback"],
          "token_endpoint_auth_method" => "none"
        },
        overrides
      )

    response = request(:post, "/oauth/register", params)
    assert response.status == 201
    Jason.decode!(response.resp_body)
  end

  def authorization(client, overrides \\ %{}) do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    params =
      Map.merge(
        %{
          "response_type" => "code",
          "client_id" => client["client_id"],
          "redirect_uri" => hd(client["redirect_uris"]),
          "scope" => "vaults:sync",
          "state" => "a-unique-state-for-the-test",
          "code_challenge_method" => "S256",
          "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
        },
        overrides
      )

    {params, verifier}
  end

  def authorize_client(client \\ register_client(), consent_params \\ %{}) do
    account = Habibi.Repo.insert!(%Habibi.Passkeys.Account{})
    {params, verifier} = authorization(client)

    browser =
      conn(:get, "/oauth/authorize?" <> URI.encode_query(params))
      |> init_test_session(%{
        account_id: account.id,
        authenticated_at: System.system_time(:second)
      })
      |> endpoint()

    assert browser.status == 200
    [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, browser.resp_body)

    approved =
      browser
      |> Phoenix.ConnTest.recycle()
      |> Phoenix.ConnTest.dispatch(
        HabibiWeb.Endpoint,
        :post,
        "/oauth/authorize",
        Map.merge(consent_params, %{
          "decision" => "allow",
          "_csrf_token" => csrf
        })
      )

    assert approved.status == 302, approved.resp_body
    [location] = get_resp_header(approved, "location")
    assert URI.to_string(%{URI.parse(location) | query: nil}) == params["redirect_uri"]
    response = URI.decode_query(URI.parse(location).query)
    assert response["state"] == params["state"]
    assert response["iss"] == Habibi.OAuth.issuer()

    {%{
       "grant_type" => "authorization_code",
       "client_id" => client["client_id"],
       "redirect_uri" => params["redirect_uri"],
       "code" => response["code"],
       "code_verifier" => verifier
     }, account}
  end

  def access_token do
    stub_subscription()
    {exchange, _} = authorize_client()
    response = request(:post, "/oauth/token", exchange)
    assert response.status == 200, response.resp_body
    Jason.decode!(response.resp_body)["access_token"]
  end

  def stub_subscription do
    Req.Test.stub(Habibi.Subscriptions, fn conn ->
      Req.Test.json(conn, %{
        subscriber: %{
          entitlements: %{
            plus: %{
              product_identifier: "habibi_plus_monthly",
              expires_date: "2099-01-01T00:00:00Z"
            }
          },
          subscriptions: %{habibi_plus_monthly: %{is_sandbox: false, refunded_at: nil}}
        }
      })
    end)
  end

  def request(method, path, params \\ nil, headers \\ []) do
    {body, type} =
      if path == "/oauth/register",
        do: {Jason.encode!(params), "application/json"},
        else: {if(params, do: URI.encode_query(params)), "application/x-www-form-urlencoded"}

    conn = conn(method, path, body) |> put_req_header("content-type", type)

    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> endpoint()
  end

  def endpoint(conn), do: HabibiWeb.Endpoint.call(conn, HabibiWeb.Endpoint.init([]))
end
