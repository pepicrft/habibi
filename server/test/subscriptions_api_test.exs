defmodule Habibi.SubscriptionsAPITest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Habibi.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    token = Habibi.AuthTestHelpers.access_token()
    %{token: token}
  end

  test "expiration, cancellation, grace, refunds and sandbox purchases govern actual write access",
       %{token: token} do
    sync_token = vault_token()
    {:ok, vault} = Habibi.Sync.create_vault(Ecto.UUID.generate(), sync_token)

    for {expires, grace, extra, allowed} <- [
          {future(), nil, %{}, true},
          {future(), nil, %{"unsubscribe_detected_at" => past()}, true},
          {past(), future(), %{}, true},
          {past(), past(), %{}, false},
          {past(), nil, %{}, false},
          {future(), nil, %{"refunded_at" => past()}, false},
          {future(), nil, %{"is_sandbox" => true}, false},
          {nil, nil, %{}, false}
        ] do
      stub(expires, grace, extra)
      status = request(:get, "/v1/subscription", token)
      assert status.status == 200
      assert Jason.decode!(status.resp_body)["active"] == allowed
      path = "/v1/vaults/#{vault.id}/records/#{Ecto.UUID.generate()}"
      response = request(:put, path, token, envelope(), sync_token)
      assert response.status == if(allowed, do: 201, else: 402)
    end
  end

  test "paywall protects all new hosted writes but never downloads or lease cleanup", %{
    token: token
  } do
    sync_token = vault_token()
    {:ok, vault} = Habibi.Sync.create_vault(Ecto.UUID.generate(), sync_token)
    id = Ecto.UUID.generate()
    record = "/v1/vaults/#{vault.id}/records/#{id}"
    assert request(:put, record, token, envelope(), sync_token).status == 201
    drafts = "/v1/vaults/#{vault.id}/drafts"

    assert request(:put, drafts, token, envelope(), sync_token, [{"if-none-match", "*"}]).status ==
             204

    lock_path = "/v1/vaults/#{vault.id}/locks/#{Ecto.UUID.generate()}"
    lease_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    lease = request(:put, lock_path, token, %{token: lease_token}, sync_token)
    assert lease.status == 200

    stub(past())

    assert request(:post, "/v1/vaults", token, %{id: Ecto.UUID.generate(), token: sync_token}).status ==
             402

    assert request(:put, record, token, envelope(), sync_token).status == 402

    assert request(:put, drafts, token, envelope(), sync_token, [
             {"if-match", "\"#{String.duplicate("a", 64)}\""}
           ]).status == 402

    assert request(:put, lock_path, token, %{token: lease_token}, sync_token).status == 402

    for path <- [record, "/v1/vaults/#{vault.id}/records", drafts] do
      assert request(:get, path, token, nil, sync_token).status == 200
    end

    assert request(
             :post,
             lock_path <> "/renew",
             token,
             %{token: lease_token, generation: 1},
             sync_token
           ).status == 200

    assert request(:delete, lock_path, token, %{token: lease_token, generation: 1}, sync_token).status ==
             200

    assert Habibi.Repo.get!(Habibi.Vault, vault.id).sequence == 1
  end

  test "receipts use the authenticated account and platform key, not posted claims", %{
    token: token
  } do
    sub = request(:get, "/v1/me", token).resp_body |> Jason.decode!() |> Map.fetch!("sub")
    receipt = String.duplicate("signed-store-token", 600)

    for {platform, key} <- [{"ios", "test-apple"}, {"android", "test-google"}] do
      Req.Test.stub(Habibi.Subscriptions, fn conn ->
        assert conn.method == "POST" and conn.request_path == "/v1/receipts"
        assert get_req_header(conn, "authorization") == ["Bearer " <> key]
        assert get_req_header(conn, "x-platform") == [platform]
        {:ok, body, conn} = read_body(conn)

        assert Jason.decode!(body) == %{
                 "app_user_id" => sub,
                 "product_id" => "habibi_plus_yearly",
                 "fetch_token" => receipt
               }

        Req.Test.json(conn, subscriber(future(), nil, %{}, "habibi_plus_yearly"))
      end)

      response =
        request(:post, "/v1/subscription/receipt", token, %{
          platform: platform,
          product_id: "habibi_plus_yearly",
          fetch_token: receipt,
          app_user_id: Ecto.UUID.generate(),
          active: true
        })

      assert response.status == 200
      assert Jason.decode!(response.resp_body)["plan"] == "plus"
    end

    assert request(:post, "/v1/subscription/receipt", token, %{
             platform: "ios",
             product_id: "other",
             fetch_token: "forged"
           }).status == 422

    assert request(:post, "/v1/subscription/receipt", nil, %{}).status == 401
    assert request(:get, "/v1/subscription", nil).status == 401
  end

  test "empty, unknown and malformed entitlement responses never grant access", %{token: token} do
    for subscriber <- [
          %{"entitlements" => %{}, "subscriptions" => %{}},
          subscriber(future(), nil, %{}, "unrelated_product")["subscriber"],
          subscriber("not-a-date", nil, %{})["subscriber"]
        ] do
      Req.Test.stub(Habibi.Subscriptions, &Req.Test.json(&1, %{"subscriber" => subscriber}))
      response = request(:get, "/v1/subscription", token)
      assert response.status == 200
      refute Jason.decode!(response.resp_body)["active"]
    end

    Req.Test.stub(Habibi.Subscriptions, &Req.Test.json(&1, %{"subscriber" => %{}}))
    assert request(:get, "/v1/subscription", token).status == 503
  end

  test "provider outage and missing configuration fail closed, without blocking reads", %{
    token: token
  } do
    sync_token = vault_token()
    {:ok, vault} = Habibi.Sync.create_vault(Ecto.UUID.generate(), sync_token)
    Req.Test.stub(Habibi.Subscriptions, &send_resp(&1, 503, "offline"))
    assert request(:get, "/v1/subscription", token).status == 503

    assert request(:post, "/v1/vaults", token, %{id: Ecto.UUID.generate(), token: sync_token}).status ==
             503

    assert request(:get, "/v1/vaults/#{vault.id}/records", token, nil, sync_token).status == 200

    config = Application.fetch_env!(:habibi, Habibi.Subscriptions)
    on_exit(fn -> Application.put_env(:habibi, Habibi.Subscriptions, config) end)
    Application.put_env(:habibi, Habibi.Subscriptions, [])
    refute Habibi.Subscriptions.available?()
    assert request(:get, "/v1/subscription", token).status == 503

    assert request(
             :put,
             "/v1/vaults/#{vault.id}/records/#{Ecto.UUID.generate()}",
             token,
             envelope(),
             sync_token
           ).status == 503
  end

  defp stub(expires, grace \\ nil, extra \\ %{}) do
    Req.Test.stub(Habibi.Subscriptions, &Req.Test.json(&1, subscriber(expires, grace, extra)))
  end

  defp subscriber(expires, grace, extra, product \\ "habibi_plus_monthly") do
    %{
      "subscriber" => %{
        "entitlements" => %{
          "plus" => %{
            "product_identifier" => product,
            "expires_date" => expires,
            "grace_period_expires_date" => grace
          }
        },
        "subscriptions" => %{
          product => Map.merge(%{"is_sandbox" => false, "refunded_at" => nil}, extra)
        }
      }
    }
  end

  defp future, do: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
  defp past, do: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
  defp envelope, do: "HAB1" <> :binary.copy(<<7>>, 64)

  defp vault_token do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp request(method, path, token, body \\ nil, vault_token \\ nil, headers \\ []) do
    {body, type} =
      if is_map(body),
        do: {Jason.encode!(body), "application/json"},
        else: {body, "application/octet-stream"}

    conn = conn(method, path, body) |> put_req_header("content-type", type)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn =
      if vault_token, do: put_req_header(conn, "x-habibi-vault-token", vault_token), else: conn

    Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
    |> Habibi.AuthTestHelpers.endpoint()
  end
end
