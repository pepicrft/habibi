defmodule Habibi.Repo.Migrations.CreateVaultDrafts do
  use Ecto.Migration

  def change do
    # One replaceable, bounded ciphertext register, not immutable vault history.
    create table(:vault_drafts, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), primary_key: true
      add :ciphertext, :binary, null: false
      add :digest, :string, size: 64, null: false
    end
  end
end
