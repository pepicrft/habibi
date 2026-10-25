defmodule Habibi.Passkeys do
  import Ecto.Query
  alias Habibi.Repo

  defmodule Account do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "passkey_accounts" do
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defmodule Key do
    use Ecto.Schema
    @primary_key {:id, :binary, autogenerate: false}
    schema "passkeys" do
      field(:account_id, :binary_id)
      field(:public_key, :binary)
      field(:sign_count, :integer)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defmodule Challenge do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "passkey_challenges" do
      field(:challenge, :binary)
      field(:kind, :string)
      field(:account_id, :binary_id)
      field(:expires_at, :utc_datetime_usec)
    end
  end

  def options(kind) when kind in ["register", "login"] do
    if kind == "register" and not Application.fetch_env!(:habibi, :allow_registration) do
      {:error, :registration_disabled}
    else
      now = DateTime.utc_now()
      Repo.delete_all(from(c in Challenge, where: c.expires_at <= ^now))
      wax = challenge(kind)

      stored =
        Repo.insert!(%Challenge{
          challenge: wax.bytes,
          kind: kind,
          account_id: Ecto.UUID.generate(),
          expires_at: DateTime.add(now, 120)
        })

      options = %{
        challenge: encode(wax.bytes),
        timeout: 120_000,
        rpId: wax.rp_id,
        userVerification: "required"
      }

      options =
        if kind == "register" do
          options
          |> Map.drop([:rpId, :userVerification])
          |> Map.merge(%{
            rp: %{id: wax.rp_id, name: "Habibi"},
            user: %{
              id: encode(Ecto.UUID.dump!(stored.account_id)),
              name: stored.account_id,
              displayName: "Habibi " <> String.slice(stored.account_id, 0, 8)
            },
            pubKeyCredParams: [%{type: "public-key", alg: -7}, %{type: "public-key", alg: -257}],
            authenticatorSelection: %{
              residentKey: "required",
              requireResidentKey: true,
              userVerification: "required"
            },
            attestation: "none"
          })
        else
          options
        end

      {:ok, stored.id, options}
    end
  end

  def options(_), do: {:error, :invalid_request}

  def finish(id, params) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {1, [stored]} <-
           Repo.delete_all(
             from(c in Challenge,
               where: c.id == ^id and c.expires_at > ^DateTime.utc_now(),
               select: c
             )
           ),
         {:ok, client_data} <- decode(params["clientDataJSON"]) do
      wax = %{
        challenge(stored.kind)
        | bytes: stored.challenge,
          issued_at: DateTime.to_unix(stored.expires_at) - 120
      }

      verify(stored, wax, params, client_data)
    else
      _ -> {:error, :invalid_passkey}
    end
  end

  defp verify(%Challenge{kind: "register"} = stored, wax, params, client_data) do
    with true <- Application.fetch_env!(:habibi, :allow_registration),
         {:ok, attestation} <- decode(params["attestationObject"]),
         {:ok,
          {%Wax.AuthenticatorData{attested_credential_data: %Wax.AttestedCredentialData{}} = data,
           _}} <-
           verify_wax(fn -> Wax.register(attestation, client_data, wax) end),
         {:ok, id} <- decode(params["id"]),
         true <- id == data.attested_credential_data.credential_id do
      Repo.transaction(fn ->
        account = Repo.insert!(%Account{id: stored.account_id})

        key = %Key{
          id: id,
          account_id: account.id,
          sign_count: data.sign_count,
          public_key: :erlang.term_to_binary(data.attested_credential_data.credential_public_key)
        }

        case Repo.insert(
               Ecto.Changeset.change(key)
               |> Ecto.Changeset.unique_constraint(:id, name: :passkeys_pkey)
             ) do
          {:ok, _} -> account
          {:error, _} -> Repo.rollback(:invalid_passkey)
        end
      end)
    else
      _ -> {:error, :invalid_passkey}
    end
  end

  defp verify(%Challenge{kind: "login"}, wax, params, client_data) do
    with {:ok, id} <- decode(params["id"]),
         {:ok, handle} <- decode(params["userHandle"]),
         {:ok, account_id} <- Ecto.UUID.load(handle),
         {:ok, auth_data} <- decode(params["authenticatorData"]),
         {:ok, signature} <- decode(params["signature"]) do
      Repo.transaction(fn ->
        with %Key{account_id: ^account_id} = key <-
               Repo.one(from(k in Key, where: k.id == ^id, lock: "FOR UPDATE")),
             public_key = :erlang.binary_to_term(key.public_key, [:safe]),
             {:ok, data} <-
               verify_wax(fn ->
                 Wax.authenticate(id, auth_data, signature, client_data, wax, [{id, public_key}])
               end),
             true <-
               data.sign_count > key.sign_count or (data.sign_count == 0 and key.sign_count == 0) do
          Repo.update!(Ecto.Changeset.change(key, sign_count: data.sign_count))
          Repo.get!(Account, account_id)
        else
          _ -> Repo.rollback(:invalid_passkey)
        end
      end)
    else
      _ -> {:error, :invalid_passkey}
    end
  end

  defp challenge(kind) do
    options = [
      origin: Habibi.OAuth.issuer(),
      rp_id: :auto,
      user_verification: "required",
      timeout: 120,
      trusted_attestation_types: [:none]
    ]

    if kind == "register",
      do: Wax.new_registration_challenge(options),
      else: Wax.new_authentication_challenge(options)
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)

  # Wax's JSON/CBOR parsers can raise for malformed input. Keep this boundary
  # around library verification only, never around database operations.
  defp verify_wax(fun) do
    fun.()
  rescue
    _ in [ArgumentError, CaseClauseError, FunctionClauseError, MatchError, KeyError] ->
      {:error, :invalid_passkey}
  end

  defp decode(value) when is_binary(value) and byte_size(value) <= 16_384,
    do: Base.url_decode64(value, padding: false)

  defp decode(_), do: :error
end
