defmodule Habibi.Sync do
  import Ecto.Query

  alias Habibi.Record
  alias Habibi.Repo
  alias Habibi.Vault

  @max_record_bytes 1024 * 1024

  def max_record_bytes, do: @max_record_bytes

  def create_vault(id, token) do
    with {:ok, id} <- uuid(id), {:ok, hash} <- token_hash(token) do
      %Vault{id: id, token_hash: hash}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:id, name: :vaults_pkey)
      |> Repo.insert()
      |> case do
        {:ok, vault} -> {:ok, vault}
        {:error, _} -> {:error, :conflict}
      end
    else
      _ -> {:error, :invalid_vault}
    end
  end

  def authorize(id, token) do
    with {:ok, id} <- uuid(id),
         {:ok, hash} <- token_hash(token),
         %Vault{token_hash: expected} = vault <- Repo.get(Vault, id),
         true <- Plug.Crypto.secure_compare(hash, expected) do
      {:ok, vault}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def put(vault, id, ciphertext, fence \\ nil) do
    with {:ok, id} <- uuid(id), :ok <- validate_envelope(ciphertext) do
      digest = :crypto.hash(:sha256, ciphertext) |> Base.encode16(case: :lower)

      Repo.transaction(fn ->
        # Serialize only one vault's writes so a cursor never skips an uncommitted record.
        current = Repo.one!(from(v in Vault, where: v.id == ^vault.id, lock: "FOR UPDATE"))

        case Repo.get_by(Record, vault_id: vault.id, id: id) do
          %Record{digest: ^digest} = record ->
            {record, :existing}

          %Record{} ->
            Repo.rollback(:conflict)

          nil ->
            Habibi.Locks.validate_fence!(current, fence)
            insert_record(current, id, ciphertext, digest, fence)
        end
      end)
    end
  end

  def list(vault, after_sequence) when is_integer(after_sequence) and after_sequence >= 0 do
    Repo.all(
      from(r in Record,
        where: r.vault_id == ^vault.id and r.sequence > ^after_sequence,
        order_by: [asc: r.sequence],
        limit: 100
      )
    )
  end

  def get(vault, id) do
    with {:ok, id} <- uuid(id),
         %Record{} = record <- Repo.get_by(Record, vault_id: vault.id, id: id) do
      storage().get(object_key(record))
    else
      _ -> {:error, :not_found}
    end
  end

  def get_drafts(vault), do: Repo.get(Habibi.VaultDraft, vault.id)

  def put_drafts(vault, ciphertext, expected) do
    with :ok <- validate_envelope(ciphertext) do
      digest = :crypto.hash(:sha256, ciphertext) |> Base.encode16(case: :lower)

      Repo.transaction(fn ->
        Repo.one!(from(v in Vault, where: v.id == ^vault.id, lock: "FOR UPDATE"))
        previous = get_drafts(vault)

        cond do
          previous && previous.digest == digest ->
            previous

          (is_nil(previous) && expected == :absent) ||
              (previous && expected == previous.digest) ->
            (previous || %Habibi.VaultDraft{vault_id: vault.id})
            |> Ecto.Changeset.change(ciphertext: ciphertext, digest: digest)
            |> Repo.insert_or_update!()

          true ->
            Repo.rollback(:precondition_failed)
        end
      end)
    end
  end

  defp insert_record(vault, id, ciphertext, digest, fence) do
    size = byte_size(ciphertext)

    if vault.bytes + size > Application.fetch_env!(:habibi, :max_vault_bytes) or
         vault.sequence >= Application.fetch_env!(:habibi, :max_vault_records) do
      Repo.rollback(:quota_exceeded)
    end

    record = %Record{
      vault_id: vault.id,
      id: id,
      sequence: vault.sequence + 1,
      bytes: size,
      digest: digest
    }

    case storage().put(object_key(record), ciphertext) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # Object storage may take longer than the lease. Never publish after expiry.
    # The vault row remains locked, excluding successor leases until commit.
    Habibi.Locks.validate_fence!(vault, fence)
    record = Repo.insert!(record)

    vault
    |> Ecto.Changeset.change(sequence: record.sequence, bytes: vault.bytes + size)
    |> Repo.update!()

    {record, :created}
  end

  defp validate_envelope(
         <<"HAB1", _salt::binary-size(32), _nonce::binary-size(12), body::binary>> = data
       )
       when byte_size(body) >= 16 and byte_size(data) <= @max_record_bytes,
       do: :ok

  defp validate_envelope(_), do: {:error, :invalid_envelope}

  defp uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, id}
      _ -> {:error, :invalid_id}
    end
  end

  defp uuid(_), do: {:error, :invalid_id}

  defp token_hash(token) when is_binary(token) and byte_size(token) == 43 do
    case Base.url_decode64(token, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, :crypto.hash(:sha256, bytes)}
      _ -> :error
    end
  end

  defp token_hash(_), do: :error

  defp object_key(record), do: "vaults/#{record.vault_id}/#{record.id}/#{record.digest}"
  defp storage, do: Application.fetch_env!(:habibi, :storage)
end
