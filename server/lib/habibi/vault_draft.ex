defmodule Habibi.VaultDraft do
  use Ecto.Schema

  @primary_key false
  schema "vault_drafts" do
    field(:vault_id, :binary_id, primary_key: true)
    field(:ciphertext, :binary)
    field(:digest, :string)
  end
end
