defmodule Habibi.LocksAPITest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  alias Habibi.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup context do
    if context[:unboxed] do
      :ok = Sandbox.checkout(Repo, sandbox: false)
      {exchange, account} = Habibi.AuthTestHelpers.authorize_client()

      response = Habibi.AuthTestHelpers.request(:post, "/oauth/token", exchange)
      assert response.status == 200
      Process.put(:oauth_token, body(response)["access_token"])

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!(
            "DELETE FROM oauth_grants WHERE id IN (SELECT grant_id FROM oauth_tokens WHERE client_id = $1)",
            [Ecto.UUID.dump!(exchange["client_id"])]
          )

          Repo.delete!(Repo.get!(Boruta.Ecto.Client, exchange["client_id"]))
          Repo.delete!(account)
        end)
      end)
    else
      owner = Sandbox.start_owner!(Repo, shared: false)
      on_exit(fn -> Sandbox.stop_owner(owner) end)
      Process.put(:oauth_token, Habibi.AuthTestHelpers.access_token())
    end

    :ok
  end

  test "acquisition is idempotent, hashes capabilities, and reports cursor and bounded contention" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    token = token()
    assert upload(vault, Ecto.UUID.generate()).status == 201

    acquired = acquire(vault, id, token)
    assert acquired.status == 200
    lease = body(acquired)
    assert lease["id"] == id
    assert lease["generation"] == 1
    assert lease["cursor"] == 1
    assert lease["lease_seconds"] == 30
    assert {:ok, _, 0} = DateTime.from_iso8601(lease["expires_at"])
    assert get_resp_header(acquired, "cache-control") == ["no-store"]
    assert body(acquire(vault, id, token)) == lease

    stored = Repo.get_by!(Habibi.VaultLock, vault_id: vault.id, id: id)
    assert stored.token_hash == :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
    refute stored.token_hash == token

    blocked = acquire(vault, id, token())
    assert blocked.status == 423
    assert body(blocked)["error"] == "locked"
    assert body(blocked)["retry_after"] in 1..5
    assert get_resp_header(blocked, "retry-after") == [to_string(body(blocked)["retry_after"])]
    assert body(acquire(vault, id, token)) == lease
  end

  test "every lock operation requires OAuth and the correct vault capability" do
    alice = new_vault()
    bob = new_vault()
    id = Ecto.UUID.generate()
    owner = token()
    assert acquire(alice, id, owner).status == 200
    assert acquire(bob, id, owner).status == 200

    for {method, suffix, params} <- [
          {:put, "", %{token: owner}},
          {:post, "/renew", %{token: owner, generation: 1}},
          {:delete, "", %{token: owner, generation: 1}}
        ] do
      for oauth <- [nil, "invalid"] do
        response = request(method, lock_path(alice, id) <> suffix, params, alice.token, [], oauth)
        assert response.status == 401
        assert body(response) == %{"error" => "invalid_token"}
      end

      for vault_token <- [nil, bob.token, "invalid"] do
        response = request(method, lock_path(alice, id) <> suffix, params, vault_token)
        assert response.status == 401
        assert body(response) == %{"error" => "unauthorized"}
      end
    end

    # Account identity does not replace or partition the vault capability.
    other_account = Habibi.AuthTestHelpers.access_token()

    assert request(:put, lock_path(alice, id), %{token: owner}, alice.token, [], other_account).status ==
             200

    # A fence from Alice cannot publish to Bob, even with Bob's valid vault token.
    alice_only = Ecto.UUID.generate()
    assert acquire(alice, alice_only, owner).status == 200
    assert upload(bob, Ecto.UUID.generate(), fence(alice_only, owner, 1)).status == 409
  end

  test "renewal and release require active token AND generation; tombstones prevent ABA" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    owner = token()
    first = acquire(vault, id, owner) |> body()

    for credentials <- [%{token: token(), generation: 1}, %{token: owner, generation: 2}] do
      assert_stale(request(:post, lock_path(vault, id) <> "/renew", credentials, vault.token))
      assert_stale(request(:delete, lock_path(vault, id), credentials, vault.token))
    end

    renewed = renew(vault, id, owner, 1)
    assert renewed.status == 200
    assert body(renewed)["generation"] == 1
    assert body(renewed)["expires_at"] >= first["expires_at"]

    assert body(release(vault, id, owner, 1)) == %{
             "id" => id,
             "generation" => 1,
             "released" => true
           }

    assert_stale(release(vault, id, owner, 1))
    assert_stale(renew(vault, id, owner, 1))
    tombstone = Repo.get_by!(Habibi.VaultLock, vault_id: vault.id, id: id)
    assert tombstone.generation == 1
    assert is_nil(tombstone.token_hash)
    assert is_nil(tombstone.expires_at)

    # Even reusing exactly the same capability cannot resurrect the old generation.
    assert body(acquire(vault, id, owner))["generation"] == 2
    assert_stale(release(vault, id, owner, 1))
    assert_stale(renew(vault, id, owner, 1))
    assert renew(vault, id, owner, 2).status == 200
  end

  test "DB wall-clock expiry permits a successor and permanently rejects the old holder" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    old = token()
    successor = token()
    assert acquire(vault, id, old).status == 200

    # This sandbox transaction started BEFORE the short expiry. PostgreSQL now()
    # is frozen at transaction start; only wall-clock expiry observes this lapse.
    Repo.query!(
      "UPDATE vault_locks SET expires_at = (clock_timestamp() AT TIME ZONE 'UTC') + interval '10 milliseconds' WHERE vault_id = $1 AND id = $2",
      [Ecto.UUID.dump!(vault.id), Ecto.UUID.dump!(id)]
    )

    Repo.query!("SELECT pg_sleep(0.02)")
    assert_stale(renew(vault, id, old, 1))
    assert_stale(release(vault, id, old, 1))
    assert body(acquire(vault, id, successor))["generation"] == 2
    assert_stale(renew(vault, id, old, 1))
    assert_stale(release(vault, id, old, 1))
    assert acquire(vault, id, old).status == 423
    assert renew(vault, id, successor, 2).status == 200
  end

  test "fenced publication rejects stale owners without consuming records, bytes or sequences" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    old = token()
    successor = token()
    assert acquire(vault, id, old).status == 200
    first_record = Ecto.UUID.generate()
    assert upload(vault, first_record, fence(id, old, 1)).status == 201
    expire(vault, id)
    rejected_record = Ecto.UUID.generate()
    assert_stale(upload(vault, rejected_record, fence(id, old, 1)))
    assert is_nil(Repo.get_by(Habibi.Record, vault_id: vault.id, id: rejected_record))
    assert Repo.get!(Habibi.Vault, vault.id).sequence == 1
    assert Repo.get!(Habibi.Vault, vault.id).bytes == 77

    assert body(acquire(vault, id, successor))["cursor"] == 1
    assert_stale(upload(vault, rejected_record, fence(id, old, 1)))
    assert_stale(upload(vault, rejected_record, fence(id, successor, 1)))
    assert upload(vault, rejected_record, fence(id, successor, 2)).status == 201

    # Lost PUT replies can be retried, even after handover: no publication occurs.
    retry = upload(vault, first_record, fence(id, old, 1))
    assert retry.status == 200
    assert body(retry)["sequence"] == 1
    assert upload(vault, first_record, fence(id, old, 1), envelope(2)).status == 409
    assert body(request(:get, records(vault), nil, vault.token))["cursor"] == 2

    assert release(vault, id, successor, 2).status == 200
    assert_stale(upload(vault, Ecto.UUID.generate(), fence(id, successor, 2)))
    assert upload(vault, Ecto.UUID.generate()).status == 201
  end

  test "a lease that expires during object upload is checked again before publication" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    owner = token()
    assert acquire(vault, id, owner).status == 200
    Process.put(:storage_put_callback, fn -> expire(vault, id) end)
    record_id = Ecto.UUID.generate()
    assert_stale(upload(vault, record_id, fence(id, owner, 1)))
    assert is_nil(Repo.get_by(Habibi.Record, vault_id: vault.id, id: record_id))
    assert Repo.get!(Habibi.Vault, vault.id).sequence == 0
    assert Repo.get!(Habibi.Vault, vault.id).bytes == 0
    Process.delete(:storage_put_callback)
    assert upload(vault, record_id, fence(id, owner, 1)).status == 201
  end

  test "malformed lock bodies and incomplete or malformed record fences are rejected" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    owner = token()

    for {lock_id, params} <- [
          {"not-a-uuid", %{token: owner}},
          {id, %{}},
          {id, %{token: "github-provider-token"}},
          {id, %{token: owner <> "="}},
          {id, %{token: :binary.copy("!", 43)}},
          {id, %{token: 1}},
          {id, %{token: owner, lease_seconds: 3600}},
          {id, %{token: owner, provider: "github"}}
        ] do
      response = request(:put, lock_path(vault, lock_id), params, vault.token)
      assert response.status == 400
      assert body(response) == %{"error" => "invalid_lock"}
    end

    assert acquire(vault, id, owner).status == 200

    for generation <- [nil, 0, -1, "1", 1.0, 9_223_372_036_854_775_808] do
      assert renew(vault, id, owner, generation).status == 400
      assert release(vault, id, owner, generation).status == 400
    end

    for headers <- [
          [{"x-habibi-lock-id", id}],
          [{"x-habibi-lock-token", owner}],
          [{"x-habibi-lock-generation", "1"}],
          fence(id, owner, "01"),
          fence(id, owner, "+1"),
          fence(id, owner, "1x"),
          fence(id, owner, "0"),
          fence(id, owner, "9223372036854775808"),
          fence("invalid", owner, 1),
          fence(id, "invalid", 1)
        ] do
      response = upload(vault, Ecto.UUID.generate(), headers)
      assert response.status == 400
      assert body(response) == %{"error" => "invalid_lock"}
    end

    assert Repo.aggregate(Habibi.VaultLock, :count) == 1
    assert Repo.get!(Habibi.Vault, vault.id).sequence == 0
  end

  test "quota includes released tombstones but allows stable ID reuse" do
    vault = new_vault()
    owner = token()

    ids =
      for _ <- 1..32 do
        id = Ecto.UUID.generate()
        assert acquire(vault, id, owner).status == 200
        assert release(vault, id, owner, 1).status == 200
        id
      end

    overflow = acquire(vault, Ecto.UUID.generate(), owner)
    assert overflow.status == 413
    assert body(overflow) == %{"error" => "lock_quota_exceeded"}
    assert body(acquire(vault, hd(ids), owner))["generation"] == 2
    assert Repo.aggregate(Habibi.VaultLock, :count) == 32
  end

  test "readiness requires the lease schema" do
    assert request(:get, "/ready", nil).status == 200
    Repo.query!("ALTER TABLE vault_locks RENAME TO vault_locks_not_ready")
    assert request(:get, "/ready", nil).status == 503
    assert request(:get, "/health", nil).status == 200
  end

  @tag :unboxed
  test "real independent PostgreSQL transactions elect one winner and cannot race past quota" do
    vault = new_vault()

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> Repo.delete!(Repo.get!(Habibi.Vault, vault.id)) end)
    end)

    id = Ecto.UUID.generate()
    results = race(vault, [id, id])
    assert Enum.sort(Enum.map(results, & &1.status)) == [200, 423]
    assert Repo.aggregate(Habibi.VaultLock, :count) == 1
    winner = Enum.find(results, &(&1.status == 200)) |> body()
    assert winner["generation"] == 1

    for _ <- 1..30, do: assert(acquire(vault, Ecto.UUID.generate(), token()).status == 200)
    results = race(vault, [Ecto.UUID.generate(), Ecto.UUID.generate()])
    assert Enum.sort(Enum.map(results, & &1.status)) == [200, 413]
    assert Repo.aggregate(Habibi.VaultLock, :count) == 32
  end

  defp race(vault, ids) do
    parent = self()
    oauth = Process.get(:oauth_token)

    tasks =
      for id <- ids do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Process.put(:oauth_token, oauth)
            # checkout(sandbox: false) pins a real independent connection. The
            # HTTP handler starts its own actual transaction on that connection.
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), backend})

            receive do
              :go -> acquire(vault, id, token())
            after
              5_000 -> flunk("concurrent acquisition barrier timed out")
            end
          end)
        end)
      end

    backends =
      for task <- tasks do
        pid = task.pid
        assert_receive {:ready, ^pid, backend}, 5_000
        backend
      end

    assert length(Enum.uniq(backends)) == length(ids), "race must use separate DB connections"
    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 10_000)
  end

  defp new_vault do
    vault = %{id: Ecto.UUID.generate(), token: token()}
    assert request(:post, "/v1/vaults", vault).status == 201
    vault
  end

  defp acquire(vault, id, owner),
    do: request(:put, lock_path(vault, id), %{token: owner}, vault.token)

  defp renew(vault, id, owner, generation),
    do:
      request(
        :post,
        lock_path(vault, id) <> "/renew",
        %{token: owner, generation: generation},
        vault.token
      )

  defp release(vault, id, owner, generation),
    do:
      request(:delete, lock_path(vault, id), %{token: owner, generation: generation}, vault.token)

  defp upload(vault, id, headers \\ [], ciphertext \\ envelope(1)),
    do: request(:put, records(vault) <> "/" <> id, ciphertext, vault.token, headers)

  defp request(method, path, payload, vault_token \\ nil, headers \\ [], oauth \\ :default) do
    {payload, type} =
      if is_map(payload),
        do: {Jason.encode!(payload), "application/json"},
        else: {payload, "application/octet-stream"}

    oauth = if oauth == :default, do: Process.get(:oauth_token), else: oauth
    conn = conn(method, path, payload) |> put_req_header("content-type", type)
    conn = if oauth, do: put_req_header(conn, "authorization", "Bearer " <> oauth), else: conn

    conn =
      if vault_token, do: put_req_header(conn, "x-habibi-vault-token", vault_token), else: conn

    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> Habibi.AuthTestHelpers.endpoint()
  end

  defp expire(vault, id) do
    Repo.query!(
      "UPDATE vault_locks SET expires_at = (clock_timestamp() AT TIME ZONE 'UTC') - interval '1 second' WHERE vault_id = $1 AND id = $2",
      [Ecto.UUID.dump!(vault.id), Ecto.UUID.dump!(id)]
    )
  end

  defp fence(id, owner, generation),
    do: [
      {"x-habibi-lock-id", id},
      {"x-habibi-lock-token", owner},
      {"x-habibi-lock-generation", to_string(generation)}
    ]

  defp assert_stale(response) do
    assert response.status == 409
    assert body(response) == %{"error" => "stale_lock"}
  end

  defp records(vault), do: "/v1/vaults/#{vault.id}/records"
  defp lock_path(vault, id), do: "/v1/vaults/#{vault.id}/locks/#{id}"
  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp envelope(byte), do: "HAB1" <> :binary.copy(<<byte>>, 73)
end
