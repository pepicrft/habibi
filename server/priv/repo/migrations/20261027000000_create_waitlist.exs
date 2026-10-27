defmodule Habibi.Repo.Migrations.CreateWaitlist do
  use Ecto.Migration

  def change do
    create table(:waitlist_entries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :email, :string, null: false
      add :code, :string, null: false
      add :referrer_id, references(:waitlist_entries, type: :uuid, on_delete: :nilify_all)
      add :confirmed_at, :utc_datetime_usec
      add :last_email_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:waitlist_entries, [:email])
    create unique_index(:waitlist_entries, [:code])
    create index(:waitlist_entries, [:referrer_id, :confirmed_at])
    create constraint(:waitlist_entries, :no_self_referrals, check: "referrer_id != id")

    create table(:waitlist_tokens, primary_key: false) do
      add :id, :binary, primary_key: true

      add :entry_id, references(:waitlist_entries, type: :uuid, on_delete: :delete_all),
        null: false

      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:waitlist_tokens, [:entry_id])
    create index(:waitlist_tokens, [:expires_at])
  end
end
