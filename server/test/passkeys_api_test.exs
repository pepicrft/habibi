defmodule Habibi.PasskeysAPITest do
  use ExUnit.Case, async: false
  import Habibi.AuthTestHelpers
  import Plug.Conn
  import Plug.Test

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Habibi.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    client = register_client()
    {params, _} = authorization(client)
    page = request(:get, "/oauth/authorize?" <> URI.encode_query(params))
    [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, page.resp_body)

    {<<4, x::binary-size(32), y::binary-size(32)>>, private} =
      :crypto.generate_key(:ecdh, :prime256v1)

    key = %{1 => 2, 3 => -7, -1 => 1, -2 => bytes(x), -3 => bytes(y)}

    %{
      page: page,
      csrf: csrf,
      key: key,
      private: private,
      id: :crypto.strong_rand_bytes(32),
      params: params
    }
  end

  test "verified resident passkeys create pseudonymous accounts and sign in with increasing counters",
       context do
    options =
      browser_post(context.page, "/auth/passkeys/options", %{kind: "register"}, context.csrf)

    registered =
      browser_post(options, "/auth/passkeys/finish", registration(context, options), context.csrf)

    assert registered.status == 200
    assert body(registered) == %{"status" => "authenticated"}

    replay =
      browser_post(options, "/auth/passkeys/finish", registration(context, options), context.csrf)

    assert replay.status == 400

    previous = Application.fetch_env!(:habibi, :allow_registration)
    Application.put_env(:habibi, :allow_registration, false)
    on_exit(fn -> Application.put_env(:habibi, :allow_registration, previous) end)

    for {count, status} <- [{3, 200}, {2, 400}, {4, 200}] do
      login = browser_post(context.page, "/auth/passkeys/options", %{kind: "login"}, context.csrf)
      data = client_data(body(login)["challenge"], "webauthn.get")
      auth = :crypto.hash(:sha256, "localhost") <> <<5, count::32>>

      signature =
        :crypto.sign(:ecdsa, :sha256, auth <> :crypto.hash(:sha256, data), [
          context.private,
          :prime256v1
        ])

      payload = %{
        id: encode(context.id),
        userHandle: body(options)["user"]["id"],
        clientDataJSON: encode(data),
        authenticatorData: encode(auth),
        signature: encode(signature)
      }

      result = browser_post(login, "/auth/passkeys/finish", payload, context.csrf)
      assert result.status == status

      if status == 200 do
        page =
          result
          |> Phoenix.ConnTest.recycle()
          |> Phoenix.ConnTest.dispatch(
            HabibiWeb.Endpoint,
            :get,
            "/oauth/authorize?" <> URI.encode_query(context.params)
          )

        assert page.resp_body =~ "You’re signed in with your passkey."
        assert page.resp_body =~ ~s(class="button-primary" name="decision" value="allow")
        assert page.resp_body =~ ~s(class="secondary" name="decision" value="deny")
        assert page.resp_body =~ ~s(class="text-button")
      end
    end
  end

  test "wrong origin, missing user verification and malformed data cannot register a passkey",
       context do
    for override <- [
          %{origin: "https://evil.example"},
          %{flags: 65},
          %{attestation: <<0>>},
          %{client_data: "[]"}
        ] do
      options =
        browser_post(context.page, "/auth/passkeys/options", %{kind: "register"}, context.csrf)

      response =
        browser_post(
          options,
          "/auth/passkeys/finish",
          registration(context, options, override),
          context.csrf
        )

      assert response.status == 400
    end

    assert Habibi.Repo.aggregate(Habibi.Passkeys.Account, :count) == 0
  end

  test "registration is closed by default policy and database-backed throttling cannot be bypassed with forwarded headers",
       context do
    options =
      browser_post(context.page, "/auth/passkeys/options", %{kind: "register"}, context.csrf)

    previous = Application.fetch_env!(:habibi, :allow_registration)
    Application.put_env(:habibi, :allow_registration, false)
    on_exit(fn -> Application.put_env(:habibi, :allow_registration, previous) end)
    assert request(:post, "/oauth/register", %{client_name: "Closed"}).status == 403

    page = request(:get, "/oauth/authorize?" <> URI.encode_query(context.params))
    assert page.resp_body =~ "New accounts are not open yet."
    refute page.resp_body =~ ~s(data-passkey="register")

    assert browser_post(context.page, "/auth/passkeys/options", %{kind: "register"}, context.csrf).status ==
             400

    assert browser_post(
             options,
             "/auth/passkeys/finish",
             registration(context, options),
             context.csrf
           ).status ==
             400

    assert Habibi.Repo.aggregate(Habibi.Passkeys.Account, :count) == 0

    for n <- 1..61 do
      conn =
        %{conn(:post, "/oauth/register", "{}") | remote_ip: {192, 0, 2, 254}}
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-forwarded-for", "192.0.2.#{n}")
        |> endpoint()

      assert conn.status == if(n <= 60, do: 403, else: 429)
    end
  end

  defp registration(context, options, overrides \\ %{}) do
    auth =
      :crypto.hash(:sha256, "localhost") <>
        <<Map.get(overrides, :flags, 69), 0::32, 0::128, 32::16>> <>
        context.id <> CBOR.encode(context.key)

    attestation =
      Map.get(
        overrides,
        :attestation,
        CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => bytes(auth)})
      )

    data =
      Map.get(
        overrides,
        :client_data,
        client_data(
          body(options)["challenge"],
          "webauthn.create",
          Map.get(overrides, :origin, Habibi.OAuth.issuer())
        )
      )

    %{
      id: encode(context.id),
      clientDataJSON: encode(data),
      attestationObject: encode(attestation)
    }
  end

  defp client_data(challenge, type, origin \\ Habibi.OAuth.issuer()),
    do: Jason.encode!(%{challenge: challenge, type: type, origin: origin})

  defp browser_post(browser, path, payload, csrf) do
    browser
    |> Phoenix.ConnTest.recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-csrf-token", csrf)
    |> Phoenix.ConnTest.dispatch(HabibiWeb.Endpoint, :post, path, Jason.encode!(payload))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp encode(value), do: Base.url_encode64(value, padding: false)
  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}
end
