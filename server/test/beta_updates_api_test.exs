defmodule Habibi.BetaUpdatesAPITest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  setup do
    previous = Application.get_env(:habibi, Habibi.BetaUpdates)
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = JOSE.JWK.to_pem(key)

    Application.put_env(:habibi, Habibi.BetaUpdates,
      key_id: "test-key",
      issuer: "test-issuer",
      private_key: Base.encode64(pem),
      request_options: [plug: {Req.Test, Habibi.BetaUpdates}]
    )

    restart()
    Req.Test.stub(Habibi.BetaUpdates, &send_resp(&1, 503, "unconfigured test"))
    :ok = Req.Test.allow(Habibi.BetaUpdates, self(), Process.whereis(Habibi.BetaUpdates))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:habibi, Habibi.BetaUpdates, previous),
        else: Application.delete_env(:habibi, Habibi.BetaUpdates)

      restart()
    end)

    %{key: key}
  end

  test "public checks return only available private-group builds and cache Apple reads", %{
    key: key
  } do
    Req.Test.stub(Habibi.BetaUpdates, fn conn ->
      query = URI.decode_query(conn.query_string)
      assert query["filter[app]"] == "6828413839"
      assert query["filter[betaGroups]"] == "01087c85-1ab4-417f-a366-775403e8fce4"
      ["Bearer " <> token] = get_req_header(conn, "authorization")
      assert {true, claims, _} = JOSE.JWT.verify_strict(key, ["ES256"], token)
      assert claims.fields["aud"] == "appstoreconnect-v1"
      assert claims.fields["iss"] == "test-issuer"
      assert claims.fields["exp"] > System.system_time(:second)
      assert claims.fields["exp"] - claims.fields["iat"] <= 305

      entries = [
        fixture("available", "IN_BETA_TESTING"),
        fixture("review", "IN_BETA_REVIEW"),
        fixture("approved", "BETA_APPROVED"),
        fixture("internal", "READY_FOR_BETA_SUBMISSION"),
        fixture("expired", "IN_BETA_TESTING", %{"expired" => true}),
        fixture("old", "IN_BETA_TESTING", %{"expirationDate" => "2020-01-01T00:00:00Z"}),
        fixture("processing", "IN_BETA_TESTING", %{"processingState" => "PROCESSING"})
      ]

      Req.Test.json(conn, %{
        data: Enum.map(entries, &elem(&1, 0)),
        included: Enum.flat_map(entries, &elem(&1, 1)),
        links: %{next: nil}
      })
    end)

    response = request()
    assert response.status == 200

    assert Jason.decode!(response.resp_body) == %{
             "builds" => [
               %{"version" => "0.2.10", "build" => "15.2", "minimumOSVersion" => "17.0"}
             ]
           }

    assert get_resp_header(response, "cache-control") == ["no-store"]
    # A repeated client check works without another Apple request.
    Req.Test.stub(Habibi.BetaUpdates, fn _ -> flunk("The Apple result should be cached") end)
    assert request().resp_body == response.resp_body
  end

  test "Apple failure and missing credentials are unavailable, not up to date" do
    Req.Test.stub(Habibi.BetaUpdates, &send_resp(&1, 503, "offline"))
    assert request().status == 503
    Application.put_env(:habibi, Habibi.BetaUpdates, [])
    restart()
    response = request()
    assert response.status == 503
    assert Jason.decode!(response.resp_body) == %{"error" => "updates_unavailable"}
  end

  test "empty beta groups succeed and pagination never sends credentials outside Apple" do
    Req.Test.stub(Habibi.BetaUpdates, &Req.Test.json(&1, %{data: [], links: %{next: nil}}))
    response = request()
    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"builds" => []}

    restart()
    :ok = Req.Test.allow(Habibi.BetaUpdates, self(), Process.whereis(Habibi.BetaUpdates))

    Req.Test.stub(Habibi.BetaUpdates, fn conn ->
      if URI.decode_query(conn.query_string)["cursor"] == "second" do
        {build, included} = fixture("second-page", "IN_BETA_TESTING")
        Req.Test.json(conn, %{data: [build], included: included})
      else
        Req.Test.json(conn, %{
          data: [],
          links: %{next: "https://api.appstoreconnect.apple.com/v1/builds?cursor=second"}
        })
      end
    end)

    assert %{"builds" => [%{"build" => "15.2"}]} = Jason.decode!(request().resp_body)

    restart()
    :ok = Req.Test.allow(Habibi.BetaUpdates, self(), Process.whereis(Habibi.BetaUpdates))

    Req.Test.stub(
      Habibi.BetaUpdates,
      &Req.Test.json(&1, %{
        data: [],
        links: %{next: "https://other.example/v1/builds?cursor=second"}
      })
    )

    assert request().status == 503
  end

  defp fixture(id, state, attributes \\ %{}) do
    build = %{
      id: id,
      type: "builds",
      attributes:
        Map.merge(
          %{
            "version" => "15.2",
            "minOsVersion" => "17.0",
            "expired" => false,
            "processingState" => "VALID",
            "expirationDate" => "2099-01-01T00:00:00Z"
          },
          attributes
        ),
      relationships: %{
        preReleaseVersion: %{data: %{id: "release-" <> id, type: "preReleaseVersions"}},
        buildBetaDetail: %{data: %{id: "detail-" <> id, type: "buildBetaDetails"}}
      }
    }

    {build,
     [
       %{
         id: "release-" <> id,
         type: "preReleaseVersions",
         attributes: %{version: "0.2.10", platform: "IOS"}
       },
       %{
         id: "detail-" <> id,
         type: "buildBetaDetails",
         attributes: %{externalBuildState: state, internalBuildState: "IN_BETA_TESTING"}
       }
     ]}
  end

  defp restart do
    :ok = Supervisor.terminate_child(Habibi.Supervisor, Habibi.BetaUpdates)
    {:ok, _} = Supervisor.restart_child(Habibi.Supervisor, Habibi.BetaUpdates)
  end

  defp request, do: conn(:get, "/v1/updates/ios") |> Habibi.AuthTestHelpers.endpoint()
end
