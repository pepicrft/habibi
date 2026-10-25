defmodule Habibi.OAuth do
  alias Boruta.Ecto.Client
  alias Habibi.Repo

  @registration_fields ~w(client_name redirect_uris token_endpoint_auth_method application_type response_types grant_types scope)
  @authorization_fields ~w(response_type client_id redirect_uri state scope code_challenge code_challenge_method created_at)

  def issuer, do: HabibiWeb.Endpoint.url()

  def register(params) do
    with true <- Application.fetch_env!(:habibi, :allow_registration),
         true <- Map.drop(params, @registration_fields) == %{},
         name when is_binary(name) and byte_size(name) in 1..100 <- params["client_name"],
         uris when is_list(uris) and length(uris) in 1..5 <- params["redirect_uris"],
         true <- Enum.all?(uris, &valid_redirect?/1),
         "none" <- params["token_endpoint_auth_method"],
         "native" <- Map.get(params, "application_type", "native"),
         ["code"] <- Map.get(params, "response_types", ["code"]),
         grants when is_list(grants) <-
           Map.get(params, "grant_types", ["authorization_code", "refresh_token"]),
         true <-
           "authorization_code" in grants and
             Enum.all?(grants, &(&1 in ["authorization_code", "refresh_token"])),
         "vaults:sync" <- Map.get(params, "scope", "vaults:sync") do
      # Boruta's admin validator requires a URI host and generates signing keys.
      # Native public clients need single-slash callbacks and no signing secrets.
      Repo.insert(%Client{
        name: name,
        secret: "",
        private_key: "",
        redirect_uris: Enum.uniq(uris),
        supported_grant_types: Enum.uniq(grants ++ ["revoke"]),
        confidential: false,
        pkce: true,
        public_refresh_token: true,
        public_revoke: true,
        access_token_ttl: 900,
        authorization_code_ttl: 60,
        id_token_ttl: 900,
        refresh_token_ttl: 2_592_000,
        token_endpoint_auth_methods: [],
        id_token_signature_alg: "HS256"
      })
    else
      false -> {:error, :invalid_client_metadata}
      _ -> {:error, :invalid_client_metadata}
    end
  end

  def validate_authorization(params) do
    with true <- Map.drop(params, @authorization_fields) == %{},
         "code" <- params["response_type"],
         "S256" <- params["code_challenge_method"],
         challenge when is_binary(challenge) <- params["code_challenge"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, challenge),
         state when is_binary(state) and byte_size(state) in 16..256 <- params["state"],
         "vaults:sync" <- params["scope"],
         redirect when is_binary(redirect) <- params["redirect_uri"],
         client when not is_nil(client) <- Boruta.Ecto.Clients.get_client(params["client_id"]),
         true <- redirect in client.redirect_uris do
      {:ok, client}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def authenticate(conn) do
    with [authorization] <- Plug.Conn.get_req_header(conn, "authorization"),
         [scheme, value] <- String.split(authorization, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         {:ok, token} <- Boruta.Oauth.Authorization.AccessToken.authorize(value: value),
         true <- "vaults:sync" in String.split(token.scope),
         {:ok, owner} <- Habibi.OAuth.ResourceOwners.get_by(sub: token.sub) do
      {:ok, owner}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp valid_redirect?(uri) when is_binary(uri) and byte_size(uri) <= 2048 do
    with {:ok, parsed} <- URI.new(uri) do
      is_nil(parsed.fragment) and is_nil(parsed.userinfo) and is_nil(parsed.query) and
        not Regex.match?(~r/[\x00-\x20\x7f*\\]/, uri) and
        is_binary(parsed.path) and String.starts_with?(parsed.path, "/") and
        ((parsed.scheme == "https" and is_binary(parsed.host) and
            Regex.match?(~r/\A[A-Za-z0-9.:-]+\z/, parsed.host)) or
           (is_binary(parsed.scheme) and parsed.scheme not in ["http", "https"] and
              Regex.match?(~r/\A[a-z][a-z0-9+-]*(?:\.[a-z0-9+-]+)+\z/, parsed.scheme) and
              is_nil(parsed.host) and is_nil(parsed.authority)))
    else
      _ -> false
    end
  end

  defp valid_redirect?(_), do: false
end

defmodule Habibi.OAuth.ResourceOwners do
  @behaviour Boruta.Oauth.ResourceOwners

  def get_by(sub: sub) do
    with {:ok, id} <- Ecto.UUID.cast(sub),
         account when not is_nil(account) <- Habibi.Repo.get(Habibi.Passkeys.Account, id) do
      {:ok, %Boruta.Oauth.ResourceOwner{sub: account.id, username: account.id}}
    else
      _ -> {:error, "Account not found"}
    end
  end

  def get_by(_), do: {:error, "Account not found"}
  def check_password(_, _), do: {:error, "Password grants are disabled"}
  def authorized_scopes(_), do: []
  def claims(_, _), do: %{}
end

defmodule Habibi.OAuth.DatabaseOnlyCache do
  # Avoid replica-local authorization state, including stale revocations.
  def get(_), do: {:ok, nil}
  def put(_, _, _opts \\ []), do: :ok
  def delete(_), do: :ok
end
