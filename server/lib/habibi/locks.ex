defmodule Habibi.Locks do
  @moduledoc """
  Vault-scoped PostgreSQL leases, shared by every server replica. Every operation
  requires OAuth `vaults:sync` authorization AND the vault capability, just like
  encrypted records. Lock IDs are opaque canonical UUIDs; owner capabilities are
  client-generated, unpadded base64url encodings of 32 random bytes (43 chars).
  Only SHA-256 capability hashes are stored. Do not use provider identifiers or
  provider tokens as IDs/capabilities. The server knows nothing about providers.

  HTTP API (JSON bodies; the vault prefix is `/v1/vaults/:vault_id`):

    * `PUT /locks/:id`, `{"token":"..."}` acquires an available lease, or
      retries an active acquisition by the same capability without extending it.
    * `POST /locks/:id/renew`, `{"token":"...","generation":1}` extends an
      active matching lease to 30 seconds from the DB clock, retaining generation.
    * `DELETE /locks/:id`, the same body, releases an active matching lease.

  Acquire/renew return 200 with `id`, `generation`, `expires_at` (UTC ISO8601),
  `lease_seconds: 30`, and `cursor` (the current committed vault sync cursor,
  sampled while holding the vault row lock, also on acquisition retries).
  Release returns 200 with `id`, `generation`, `released: true`.
  All errors are `{"error":"code"}` except contention, which returns 423
  `{"error":"locked","retry_after":N}` with a `Retry-After: N` header,
  where N is 1..5 seconds. Other codes: 400 `invalid_lock`, 401 `invalid_token`
  (OAuth) / `unauthorized` (vault), 409 `stale_lock`, 413 `lock_quota_exceeded`.

  A lease is expired at `expires_at <= clock_timestamp()` and cannot be renewed
  or released after expiry. Reacquisition, including by the old capability,
  increments generation. Release clears the capability/expiry but permanently
  retains the generation tombstone. Repeated release is stale, not successful.
  There are at most 32 distinct IDs per vault, INCLUDING tombstones; reuse stable
  opaque IDs rather than allocating a new one for every operation. Generations
  never wrap; the theoretical exhausted bigint returns 409 `lock_exhausted`.

  Optional record PUT fencing uses ALL of `X-Habibi-Lock-Id`,
  `X-Habibi-Lock-Token`, `X-Habibi-Lock-Generation` (canonical positive decimal).
  Partial/malformed fences return 400 `invalid_lock`. A well-formed fence must
  name an active owner in this vault or a NEW record is rejected with 409
  `stale_lock`, without consuming a sync sequence or publishing metadata.
  The check and insert share the same vault-row-serialized DB transaction;
  expiry is checked again after object upload, immediately before publication.
  For an existing record with identical ciphertext digest, PUT returns 200
  even with an expired/stale but syntactically valid fence: nothing is published
  and no sequence is consumed. Different ciphertext at an existing ID is 409
  `conflict`. Unfenced record APIs remain unchanged.

  Hosts should acquire, sync through the returned cursor and re-read encrypted
  credentials BEFORE deciding whether to refresh; wait/poll on 423. Fencing
  protects only server publication by cooperative callers, NOT provider calls.
  A paused stale process can still contact GitHub after its lease expires.
  Timeout/crash after provider token rotation can lose the new token: a generic
  lease alone cannot make refresh safe. Reconnect or a provider-appropriate
  durable in-progress/recovery protocol is still required. This server neither
  refreshes credentials nor claims provider-side exactly-once execution.
  """

  import Ecto.Query

  alias Habibi.{Repo, Vault, VaultLock}

  @lease_seconds 30
  @max_per_vault 32
  @max_generation 9_223_372_036_854_775_807

  def lease_seconds, do: @lease_seconds
  def max_per_vault, do: @max_per_vault

  def acquire(vault, id, %{"token" => token} = params) when map_size(params) == 1 do
    with {:ok, id} <- uuid(id), {:ok, hash} <- token_hash(token) do
      serialized(vault, fn current, now ->
        lease = Repo.get_by(VaultLock, vault_id: vault.id, id: id)

        cond do
          active?(lease, now) and owner?(lease, hash) ->
            metadata(lease, current)

          active?(lease, now) ->
            remaining = DateTime.diff(lease.expires_at, now, :microsecond)
            Repo.rollback({:locked, min(5, max(1, div(remaining + 999_999, 1_000_000)))})

          is_nil(lease) ->
            count = Repo.aggregate(from(l in VaultLock, where: l.vault_id == ^vault.id), :count)
            if count >= @max_per_vault, do: Repo.rollback(:lock_quota_exceeded)

            %VaultLock{vault_id: vault.id, id: id, generation: 1}
            |> Ecto.Changeset.change(token_hash: hash, expires_at: expiry(now))
            |> Repo.insert!()
            |> metadata(current)

          lease.generation == @max_generation ->
            Repo.rollback(:lock_exhausted)

          true ->
            lease
            |> Ecto.Changeset.change(
              token_hash: hash,
              expires_at: expiry(now),
              generation: lease.generation + 1
            )
            |> Repo.update!()
            |> metadata(current)
        end
      end)
    end
  end

  def acquire(_, _, _), do: {:error, :invalid_lock}

  def renew(vault, id, params), do: change_lease(vault, id, params, :renew)
  def release(vault, id, params), do: change_lease(vault, id, params, :release)

  def fence(id, token, generation) do
    with {:ok, id} <- uuid(id),
         {:ok, hash} <- token_hash(token),
         true <- is_integer(generation) and generation > 0 and generation <= @max_generation do
      {:ok, %{id: id, token_hash: hash, generation: generation}}
    else
      _ -> {:error, :invalid_lock}
    end
  end

  # The caller MUST hold the vault row lock in this transaction until publication.
  def validate_fence!(_vault, nil), do: :ok

  def validate_fence!(vault, fence) do
    lease = Repo.get_by(VaultLock, vault_id: vault.id, id: fence.id)

    unless active?(lease, db_now()) and owner?(lease, fence.token_hash) and
             lease.generation == fence.generation do
      Repo.rollback(:stale_lock)
    end

    :ok
  end

  defp change_lease(vault, id, %{"token" => token, "generation" => generation} = params, action)
       when map_size(params) == 2 do
    with {:ok, fence} <- fence(id, token, generation) do
      serialized(vault, fn current, now ->
        lease = Repo.get_by(VaultLock, vault_id: vault.id, id: fence.id)

        unless active?(lease, now) and owner?(lease, fence.token_hash) and
                 lease.generation == fence.generation do
          Repo.rollback(:stale_lock)
        end

        case action do
          :renew ->
            lease
            |> Ecto.Changeset.change(expires_at: expiry(now))
            |> Repo.update!()
            |> metadata(current)

          :release ->
            lease |> Ecto.Changeset.change(token_hash: nil, expires_at: nil) |> Repo.update!()
            %{id: lease.id, generation: lease.generation, released: true}
        end
      end)
    end
  end

  defp change_lease(_, _, _, _), do: {:error, :invalid_lock}

  defp serialized(vault, operation) do
    Repo.transaction(fn ->
      current = Repo.one!(from(v in Vault, where: v.id == ^vault.id, lock: "FOR UPDATE"))
      operation.(current, db_now())
    end)
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp expiry(now), do: DateTime.add(now, @lease_seconds, :second)
  defp active?(nil, _now), do: false
  defp active?(%VaultLock{expires_at: nil}, _now), do: false
  defp active?(lease, now), do: DateTime.compare(lease.expires_at, now) == :gt
  defp owner?(%VaultLock{token_hash: nil}, _hash), do: false
  defp owner?(lease, hash), do: Plug.Crypto.secure_compare(lease.token_hash, hash)

  defp metadata(lease, vault) do
    %{
      id: lease.id,
      generation: lease.generation,
      expires_at: lease.expires_at,
      lease_seconds: @lease_seconds,
      cursor: vault.sequence
    }
  end

  defp uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, id}
      _ -> {:error, :invalid_lock}
    end
  end

  defp uuid(_), do: {:error, :invalid_lock}

  defp token_hash(token) when is_binary(token) and byte_size(token) == 43 do
    with {:ok, bytes} <- Base.url_decode64(token, padding: false),
         true <- byte_size(bytes) == 32 and Base.url_encode64(bytes, padding: false) == token do
      {:ok, :crypto.hash(:sha256, bytes)}
    else
      _ -> {:error, :invalid_lock}
    end
  end

  defp token_hash(_), do: {:error, :invalid_lock}
end
