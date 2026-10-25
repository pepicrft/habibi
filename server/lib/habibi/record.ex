defmodule Habibi.Record do
  use Ecto.Schema

  @primary_key false
  schema "records" do
    field(:vault_id, :binary_id, primary_key: true)
    field(:id, :binary_id, primary_key: true)
    field(:sequence, :integer)
    field(:bytes, :integer)
    field(:digest, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
