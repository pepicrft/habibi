defmodule Habibi.Vault do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "vaults" do
    field(:token_hash, :binary)
    field(:sequence, :integer, default: 0)
    field(:bytes, :integer, default: 0)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
