defmodule Habibi.Repo.Migrations.CreateNativeAuth do
  use Ecto.Migration

  def change do
    create table(:passkey_accounts, primary_key: false) do
      add :id, :uuid, primary_key: true
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:passkeys, primary_key: false) do
      add :id, :binary, primary_key: true

      add :account_id, references(:passkey_accounts, type: :uuid, on_delete: :delete_all),
        null: false

      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:passkeys, [:account_id])

    create table(:passkey_challenges, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :challenge, :binary, null: false
      add :kind, :string, null: false
      add :account_id, :uuid, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:passkey_challenges, [:expires_at])

    create table(:oauth_grants, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :revoked_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
    end

    alter table(:oauth_tokens) do
      add :grant_id, references(:oauth_grants, type: :uuid, on_delete: :delete_all), null: false
    end

    create index(:oauth_tokens, [:grant_id])
    create unique_index(:oauth_tokens, [:value], name: :oauth_tokens_value_unique)
    create unique_index(:oauth_tokens, [:refresh_token])

    create table(:auth_rate_limits, primary_key: false) do
      add :id, :binary, primary_key: true
      add :count, :integer, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:auth_rate_limits, [:expires_at])

    execute "INSERT INTO oauth_scopes (id, name, public, inserted_at, updated_at) VALUES (gen_random_uuid(), 'vaults:sync', true, now(), now())",
            "DELETE FROM oauth_scopes WHERE name = 'vaults:sync'"
  end
end
