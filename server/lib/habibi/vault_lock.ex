defmodule Habibi.VaultLock do
  use Ecto.Schema

  @primary_key false
  schema "vault_locks" do
    field(:vault_id, :binary_id, primary_key: true)
    field(:id, :binary_id, primary_key: true)
    field(:generation, :integer)
    field(:token_hash, :binary)
    field(:expires_at, :utc_datetime_usec)
  end
end
