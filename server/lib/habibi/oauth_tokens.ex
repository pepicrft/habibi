defmodule Habibi.OAuth.Tokens do
  @behaviour Boruta.Oauth.AccessTokens

  import Ecto.Query
  alias Habibi.Repo

  defmodule Grant do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "oauth_grants" do
      field(:revoked_at, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
    end
  end

  defmodule StoredToken do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "oauth_tokens" do
      field(:type, :string)
      field(:value, :string)
      field(:refresh_token, :string)
      field(:client_id, :binary_id)
      field(:grant_id, :binary_id)
      field(:sub, :string)
      field(:scope, :string)
      field(:redirect_uri, :string)
      field(:expires_at, :integer)
      field(:revoked_at, :utc_datetime_usec)
      field(:refresh_token_revoked_at, :utc_datetime_usec)
      field(:code_challenge_hash, :string)
      field(:code_challenge_method, :string)
      timestamps(type: :utc_datetime_usec)
    end
  end

  def get_by(value: value, redirect_uri: redirect) do
    with %StoredToken{type: "code", redirect_uri: ^redirect} = token <- find(:value, value) do
      to_oauth(token)
    else
      _ -> nil
    end
  end

  def get_by([{field, value}]) when field in [:value, :refresh_token] do
    with %StoredToken{type: "access_token"} = token <- find(field, value) do
      to_oauth(token)
    else
      _ -> nil
    end
  end

  def create(params) do
    grant = Repo.insert!(%Grant{expires_at: DateTime.add(DateTime.utc_now(), 2_592_000)})
    insert(params, "code", grant.id, params.client.authorization_code_ttl)
  end

  def create(params, _opts) do
    previous = Repo.get_by!(StoredToken, value: params[:previous_token] || params[:previous_code])
    insert(params, "access_token", previous.grant_id, params.client.access_token_ttl)
  end

  defp insert(params, kind, grant_id, ttl) do
    value = random()

    refresh =
      if kind == "access_token" and "refresh_token" in params.client.supported_grant_types,
        do: random()

    now = DateTime.utc_now()

    token =
      Repo.insert!(%StoredToken{
        type: kind,
        value: digest(value),
        refresh_token: refresh && digest(refresh),
        client_id: params.client.id,
        grant_id: grant_id,
        sub: params.sub,
        scope: params.scope,
        redirect_uri: params[:redirect_uri],
        expires_at: DateTime.to_unix(now) + ttl,
        code_challenge_hash:
          params[:code_challenge] && Boruta.Oauth.Token.hash(params.code_challenge),
        code_challenge_method: if(kind == "code", do: "S256")
      })

    {:ok, %{to_oauth(token) | value: value, refresh_token: refresh, state: params[:state]}}
  end

  def revoke(%Boruta.Oauth.Token{type: "code", value: hash} = token) do
    Repo.update_all(from(t in StoredToken, where: t.value == ^hash),
      set: [revoked_at: DateTime.utc_now()]
    )

    {:ok, token}
  end

  def revoke(%Boruta.Oauth.Token{value: hash} = token) do
    stored = Repo.get_by!(StoredToken, value: hash)
    revoke_grant(stored.grant_id)
    {:ok, token}
  end

  def revoke_refresh_token(%Boruta.Oauth.Token{value: hash} = token) do
    Repo.update_all(from(t in StoredToken, where: t.value == ^hash),
      set: [refresh_token_revoked_at: DateTime.utc_now()]
    )

    {:ok, token}
  end

  def revoke_previous_token(%Boruta.Oauth.Token{value: hash} = token) do
    stored = Repo.get_by!(StoredToken, value: hash)
    revoke_grant(stored.grant_id)
    {:ok, token}
  end

  # Lock the whole grant, not a BEAM process or just the presented token. Rotation,
  # revocation, and replay detection must serialize across every application node.
  def transaction(params, action, fun) do
    Repo.transaction(fn ->
      field =
        if params["grant_type"] == "refresh_token" or params["token_type_hint"] == "refresh_token",
          do: :refresh_token,
          else: :value

      value = params["code"] || params["refresh_token"] || params["token"]

      stored =
        find(field, value) ||
          if(action == :revoke, do: find(:refresh_token, value) || find(:value, value))

      if stored do
        Repo.one!(from(g in Grant, where: g.id == ^stored.grant_id, lock: "FOR UPDATE"))
        stored = Repo.get!(StoredToken, stored.id)

        cond do
          stored.client_id != params["client_id"] ->
            if action == :revoke, do: :ok, else: {:error, :bad_request, :invalid_grant}

          action == :token and params["grant_type"] == "authorization_code" and
              (stored.type != "code" or stored.redirect_uri != params["redirect_uri"]) ->
            {:error, :bad_request, :invalid_grant}

          action == :token and replay?(stored, params) ->
            revoke_grant(stored.grant_id)
            {:error, :bad_request, :invalid_grant}

          true ->
            fun.(stored.scope)
        end
      else
        fun.(nil)
      end
    end)
  end

  defp replay?(
         %StoredToken{type: "code", revoked_at: revoked} = token,
         %{"grant_type" => "authorization_code"} = params
       )
       when not is_nil(revoked) do
    verifier = params["code_verifier"]

    is_binary(verifier) and params["redirect_uri"] == token.redirect_uri and
      Plug.Crypto.secure_compare(
        token.code_challenge_hash,
        Boruta.Oauth.Token.hash(
          Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
        )
      )
  end

  defp replay?(%StoredToken{refresh_token_revoked_at: revoked}, %{"grant_type" => "refresh_token"}),
       do: not is_nil(revoked)

  defp replay?(_, _), do: false

  defp revoke_grant(id) do
    Repo.update_all(from(g in Grant, where: g.id == ^id), set: [revoked_at: DateTime.utc_now()])
  end

  defp find(field, value) when is_binary(value) and byte_size(value) in 1..256 do
    Repo.get_by(StoredToken, [{field, digest(value)}])
  end

  defp find(_, _), do: nil

  defp to_oauth(token) do
    grant = Repo.get!(Grant, token.grant_id)

    revoked =
      token.revoked_at || grant.revoked_at ||
        if(DateTime.compare(grant.expires_at, DateTime.utc_now()) != :gt, do: grant.expires_at)

    owner =
      case Habibi.OAuth.ResourceOwners.get_by(sub: token.sub) do
        {:ok, owner} -> owner
        _ -> nil
      end

    struct(Boruta.Oauth.Token, Map.from_struct(token))
    |> Map.merge(%{
      revoked_at: revoked,
      resource_owner: owner,
      client: Boruta.Ecto.Clients.get_client(token.client_id)
    })
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end

defmodule Habibi.OAuth.Codes do
  @behaviour Boruta.Oauth.Codes
  defdelegate get_by(params), to: Habibi.OAuth.Tokens
  defdelegate create(params), to: Habibi.OAuth.Tokens
  defdelegate revoke(token), to: Habibi.OAuth.Tokens
  defdelegate revoke_previous_token(token), to: Habibi.OAuth.Tokens
end
