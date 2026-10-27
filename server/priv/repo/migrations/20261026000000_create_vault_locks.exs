defmodule Habibi.Repo.Migrations.CreateVaultLocks do
  use Ecto.Migration

  def change do
    create table(:vault_locks, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), primary_key: true
      add :id, :uuid, primary_key: true
      add :generation, :bigint, null: false
      add :token_hash, :binary
      add :expires_at, :utc_datetime_usec
    end

    create constraint(:vault_locks, :positive_generation, check: "generation > 0")

    create constraint(:vault_locks, :lease_owner,
             check:
               "(token_hash IS NULL AND expires_at IS NULL) OR (octet_length(token_hash) = 32 AND token_hash IS NOT NULL AND expires_at IS NOT NULL)"
           )
  end
end
