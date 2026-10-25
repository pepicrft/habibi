defmodule HabibiWeb.OAuthController do
  use Phoenix.Controller, formats: [:json, :html]
  use Gettext, backend: HabibiWeb.AuthGettext
  import Plug.Conn
  alias Habibi.OAuth
  alias Habibi.OAuth.Tokens
  alias HabibiWeb.{AuthGettext, AuthLocale}

  @behaviour Boruta.Oauth.TokenApplication
  @behaviour Boruta.Oauth.RevokeApplication
  @behaviour Boruta.Oauth.AuthorizeApplication
  @authorization_fields ~w(response_type client_id redirect_uri state scope code_challenge code_challenge_method)

  require EEx

  EEx.function_from_file(
    :defp,
    :page,
    Path.expand("../../priv/templates/authorize.html.eex", __DIR__),
    [:assigns],
    engine: Phoenix.HTML.Engine
  )

  def metadata(conn, _) do
    issuer = OAuth.issuer()

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: issuer <> "/oauth/authorize",
      token_endpoint: issuer <> "/oauth/token",
      registration_endpoint: issuer <> "/oauth/register",
      revocation_endpoint: issuer <> "/oauth/revoke",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["none"],
      revocation_endpoint_auth_methods_supported: ["none"],
      code_challenge_methods_supported: ["S256"],
      scopes_supported: ["vaults:sync"],
      authorization_response_iss_parameter_supported: true
    })
  end

  def register(conn, params) do
    if Application.fetch_env!(:habibi, :allow_registration) do
      case OAuth.register(params) do
        {:ok, client} ->
          conn
          |> put_status(201)
          |> json(%{
            client_id: client.id,
            client_name: client.name,
            redirect_uris: client.redirect_uris,
            application_type: "native",
            token_endpoint_auth_method: "none",
            grant_types: client.supported_grant_types -- ["revoke"],
            response_types: ["code"],
            scope: "vaults:sync",
            client_id_issued_at: DateTime.to_unix(client.inserted_at)
          })

        _ ->
          failure(conn, 400, :invalid_client_metadata)
      end
    else
      failure(conn, 403, :registration_disabled)
    end
  end

  def authorize(conn, params) do
    with {:ok, client} <- OAuth.validate_authorization(params) do
      pending =
        Map.take(params, @authorization_fields)
        |> Map.put("created_at", System.system_time(:second))

      conn =
        conn |> put_session(:authorization, pending) |> browser_headers(pending["redirect_uri"])

      locale = AuthLocale.select(get_req_header(conn, "accept-language"))

      Gettext.with_locale(AuthGettext, locale, fn ->
        html(
          conn |> put_resp_header("content-language", AuthLocale.language_tag(locale)),
          Phoenix.HTML.safe_to_string(
            page(%{
              locale: AuthLocale.language_tag(locale),
              direction: AuthLocale.direction(locale),
              client: client,
              redirect_uri: pending["redirect_uri"],
              csrf: Plug.CSRFProtection.get_csrf_token(),
              signed_in: not is_nil(owner(conn)),
              registration: Application.fetch_env!(:habibi, :allow_registration)
            })
          )
        )
      end)
    else
      _ -> failure(conn, 400, :invalid_request)
    end
  end

  def consent(conn, params) do
    with pending when is_map(pending) <- get_session(conn, :authorization),
         true <- (System.system_time(:second) - pending["created_at"]) in 0..600,
         {:ok, _} <- OAuth.validate_authorization(pending),
         user when not is_nil(user) <- owner(conn) do
      conn = conn |> delete_session(:authorization) |> browser_headers(pending["redirect_uri"])

      if params["decision"] == "allow" do
        {:ok, result} =
          Habibi.Repo.transaction(fn ->
            request = %{conn | params: pending, query_params: pending, body_params: %{}}
            Boruta.Oauth.authorize(request, user, __MODULE__)
          end)

        case result do
          {:ok, response} ->
            redirect(conn,
              external:
                response_url(response.redirect_uri, %{code: response.code, state: response.state})
            )

          {:error, status, error} ->
            failure(conn, status, error)
        end
      else
        redirect(conn,
          external:
            response_url(pending["redirect_uri"], %{
              error: "access_denied",
              state: pending["state"]
            })
        )
      end
    else
      _ -> failure(conn, 400, :invalid_request)
    end
  end

  def passkey_options(conn, params) do
    case Habibi.Passkeys.options(params["kind"]) do
      {:ok, challenge, options} ->
        conn |> put_session(:passkey_challenge, challenge) |> json(options)

      {:error, reason} ->
        failure(conn, 400, reason)
    end
  end

  def passkey_finish(conn, params) do
    challenge = get_session(conn, :passkey_challenge)
    conn = delete_session(conn, :passkey_challenge)

    case Habibi.Passkeys.finish(challenge, params) do
      {:ok, account} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:account_id, account.id)
        |> put_session(:authenticated_at, System.system_time(:second))
        |> json(%{status: "authenticated"})

      _ ->
        failure(conn, 400, :invalid_passkey)
    end
  end

  def logout(conn, _) do
    conn |> configure_session(drop: true) |> redirect(to: "/")
  end

  def token(conn, %{"grant_type" => grant} = params)
      when grant in ["authorization_code", "refresh_token"] do
    if valid_token_request?(params) and get_req_header(conn, "authorization") == [] do
      {:ok, result} =
        Tokens.transaction(params, :token, fn scope ->
          params =
            if grant == "refresh_token" and not Map.has_key?(params, "scope"),
              do: Map.put(params, "scope", scope || ""),
              else: params

          Boruta.Oauth.token(%{conn | params: params, body_params: params}, __MODULE__)
        end)

      token_result(conn, result)
    else
      failure(conn, 400, :invalid_request)
    end
  end

  def token(conn, _), do: failure(conn, 400, :unsupported_grant_type)

  def revoke(conn, params) do
    if fields?(params, ~w(client_id token token_type_hint)) and
         is_binary(params["client_id"]) and is_binary(params["token"]) and
         get_req_header(conn, "authorization") == [] do
      {:ok, result} =
        Tokens.transaction(params, :revoke, fn _ ->
          Boruta.Oauth.revoke(%{conn | body_params: params, query_params: %{}}, __MODULE__)
        end)

      case result do
        :ok -> send_resp(conn, 200, "")
        {:error, status, error} -> failure(conn, status, error)
      end
    else
      failure(conn, 400, :invalid_request)
    end
  end

  def me(conn, _) do
    case OAuth.authenticate(conn) do
      {:ok, owner} ->
        json(conn, %{sub: owner.sub})

      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="habibi"))
        |> failure(401, :invalid_token)
    end
  end

  def token_success(_conn, response) do
    {:ok,
     %{
       access_token: response.access_token,
       refresh_token: response.refresh_token,
       token_type: response.token_type,
       expires_in: response.expires_in,
       scope: response.token.scope
     }
     |> Map.reject(fn {_, value} -> is_nil(value) end)}
  end

  def token_error(_conn, error), do: {:error, error.status, error.error}
  def revoke_success(_conn), do: :ok
  def revoke_error(_conn, error), do: {:error, error.status, error.error}
  def authorize_success(_conn, response), do: {:ok, response}
  def authorize_error(_conn, error), do: {:error, error.status, error.error}
  def preauthorize_success(_conn, response), do: {:ok, response}
  def preauthorize_error(_conn, error), do: {:error, error.status, error.error}

  defp token_result(conn, {:ok, payload}),
    do: conn |> put_resp_header("pragma", "no-cache") |> json(payload)

  defp token_result(conn, {:error, status, error}), do: failure(conn, status, error)
  defp failure(conn, status, error), do: conn |> put_status(status) |> json(%{error: error})

  defp valid_token_request?(%{"grant_type" => "authorization_code"} = params) do
    fields?(params, ~w(grant_type client_id code redirect_uri code_verifier)) and
      is_binary(params["code_verifier"]) and
      Regex.match?(~r/\A[A-Za-z0-9._~-]{43,128}\z/, params["code_verifier"])
  end

  defp valid_token_request?(params),
    do: fields?(params, ~w(grant_type client_id refresh_token scope))

  defp fields?(params, fields) do
    Map.drop(params, fields) == %{} and Enum.all?(params, fn {_, value} -> is_binary(value) end)
  end

  defp owner(conn) do
    with time when is_integer(time) <- get_session(conn, :authenticated_at),
         true <- (System.system_time(:second) - time) in 0..900,
         {:ok, user} <- OAuth.ResourceOwners.get_by(sub: get_session(conn, :account_id)) do
      user
    else
      _ -> nil
    end
  end

  defp response_url(uri, params) do
    uri <> "?" <> URI.encode_query(Map.put(params, :iss, OAuth.issuer()))
  end

  defp browser_headers(conn, callback) do
    # Browsers also apply form-action to the POST's redirect. Permit only the
    # validated callback (or native scheme), alongside same-origin form submits.
    uri = URI.new!(callback)

    destination =
      if uri.scheme == "https",
        do: URI.to_string(%{uri | path: nil}),
        else: uri.scheme <> ":"

    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; form-action 'self' #{destination}; frame-ancestors 'none'; base-uri 'none'"
    )
  end
end
