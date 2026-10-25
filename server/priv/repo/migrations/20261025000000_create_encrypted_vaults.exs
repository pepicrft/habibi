defmodule Habibi.Repo.Migrations.CreateEncryptedVaults do
  use Ecto.Migration

  def change do
    create table(:vaults, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :token_hash, :binary, null: false
      add :sequence, :bigint, null: false, default: 0
      add :bytes, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:records, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), primary_key: true
      add :id, :uuid, primary_key: true
      add :sequence, :bigint, null: false
      add :bytes, :integer, null: false
      add :digest, :string, size: 64, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:records, [:vault_id, :sequence])
  end
end
