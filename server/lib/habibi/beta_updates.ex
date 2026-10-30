defmodule Habibi.BetaUpdates do
  @moduledoc "Cached public build metadata. Apple credentials and tester identities never reach clients."
  use GenServer

  @app "6828413839"
  @group "01087c85-1ab4-417f-a366-775403e8fce4"
  @origin "https://api.appstoreconnect.apple.com/v1"

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, nil, options)
  def latest(server \\ __MODULE__), do: GenServer.call(server, :latest, 30_000)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call(:latest, _from, cache) do
    now = System.monotonic_time(:second)

    {result, expires} =
      case cache do
        {result, expires} when expires > now ->
          {result, expires}

        _ ->
          result = fetch()
          {result, now + if(match?({:ok, _}, result), do: 300, else: 30)}
      end

    {:reply, result, {result, expires}}
  end

  defp fetch do
    config = Application.get_env(:habibi, __MODULE__, [])

    with key_id when is_binary(key_id) and key_id != "" <- config[:key_id],
         issuer when is_binary(issuer) and issuer != "" <- config[:issuer],
         encoded when is_binary(encoded) <- config[:private_key],
         {:ok, pem} <- Base.decode64(encoded) do
      seconds = System.system_time(:second)

      {_, token} =
        JOSE.JWT.sign(
          JOSE.JWK.from_pem(pem),
          %{"alg" => "ES256", "kid" => key_id, "typ" => "JWT"},
          %{
            "iss" => issuer,
            "iat" => seconds - 5,
            "exp" => seconds + 300,
            "aud" => "appstoreconnect-v1"
          }
        )
        |> JOSE.JWS.compact()

      query =
        URI.encode_query(%{
          "filter[app]" => @app,
          "filter[betaGroups]" => @group,
          "filter[preReleaseVersion.platform]" => "IOS",
          "filter[expired]" => "false",
          "filter[processingState]" => "VALID",
          "include" => "preReleaseVersion,buildBetaDetail",
          "limit" => "200"
        })

      with {:ok, builds} <- page(@origin <> "/builds?" <> query, token, config, 3) do
        {:ok, %{builds: builds}}
      end
    else
      _ -> {:error, :updates_unavailable}
    end
  rescue
    _ -> {:error, :updates_unavailable}
  end

  defp page(url, token, config, remaining) when remaining > 0 do
    options =
      Keyword.merge(
        [
          url: url,
          auth: {:bearer, token},
          retry: false,
          redirect: false,
          receive_timeout: 5_000,
          connect_options: [timeout: 3_000]
        ],
        config[:request_options] || []
      )

    with {:ok, %{status: 200, body: %{"data" => builds} = body}} <-
           Req.get(options),
         included = Map.get(body, "included", []),
         true <- is_list(builds) and is_list(included) do
      available = Enum.flat_map(builds, &available(&1, included))

      case get_in(body, ["links", "next"]) do
        nil ->
          {:ok, available}

        @origin <> "/builds?" <> _ = next ->
          with {:ok, rest} <- page(next, token, config, remaining - 1),
               do: {:ok, available ++ rest}

        _ ->
          {:error, :updates_unavailable}
      end
    else
      _ -> {:error, :updates_unavailable}
    end
  end

  defp page(_, _, _, _), do: {:error, :updates_unavailable}

  defp available(build, included) do
    attributes = build["attributes"] || %{}
    detail = related(build, included, "buildBetaDetail")
    release = related(build, included, "preReleaseVersion")

    with false <- attributes["expired"],
         "VALID" <- attributes["processingState"],
         "IN_BETA_TESTING" <- detail["externalBuildState"],
         "IOS" <- release["platform"],
         {:ok, expiration, _} <- DateTime.from_iso8601(attributes["expirationDate"] || ""),
         :gt <- DateTime.compare(expiration, DateTime.utc_now()),
         true <- numeric?(attributes["version"]),
         true <- numeric?(release["version"]),
         true <- numeric?(attributes["minOsVersion"]) do
      [
        %{
          version: release["version"],
          build: attributes["version"],
          minimumOSVersion: attributes["minOsVersion"]
        }
      ]
    else
      _ -> []
    end
  end

  defp related(build, included, relationship) do
    reference = get_in(build, ["relationships", relationship, "data"])

    Enum.find_value(included, %{}, fn item ->
      if reference && item["id"] == reference["id"] && item["type"] == reference["type"],
        do: item["attributes"]
    end)
  end

  defp numeric?(value),
    do: is_binary(value) and Regex.match?(~r/^\d{1,9}(\.\d{1,9}){0,2}$/, value)
end
