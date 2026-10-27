defmodule Habibi.SyncAPITest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Habibi.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Process.put(:oauth_token, Habibi.AuthTestHelpers.access_token())
    :ok
  end

  test "readiness waits for the sync schema while liveness stays independent" do
    assert request(:get, "/ready", nil).status == 200

    for table <- ["records", "vault_drafts", "waitlist_entries", "waitlist_tokens"] do
      Ecto.Adapters.SQL.query!(Habibi.Repo, "ALTER TABLE #{table} RENAME TO #{table}_not_ready")
      assert request(:get, "/ready", nil).status == 503
      Ecto.Adapters.SQL.query!(Habibi.Repo, "ALTER TABLE #{table}_not_ready RENAME TO #{table}")
    end

    assert request(:get, "/health", nil).status == 200
  end

  test "opaque records round-trip, retries are idempotent and replacements conflict" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    bytes = envelope(91)
    first = request(:put, path(vault, id), bytes, vault.token)
    assert first.status == 201
    assert request(:put, path(vault, id), bytes, vault.token).status == 200
    assert request(:put, path(vault, id), envelope(92), vault.token).status == 409

    download = request(:get, path(vault, id), nil, vault.token)
    assert download.status == 200
    assert download.resp_body == bytes
    assert get_resp_header(download, "cache-control") == ["no-store"]

    second_id = Ecto.UUID.generate()
    assert request(:put, path(vault, second_id), envelope(93), vault.token).status == 201
    listing = request(:get, path(vault), nil, vault.token) |> body()
    assert Enum.map(listing["records"], & &1["id"]) == [id, second_id]
    assert listing["cursor"] == 2

    tail = request(:get, path(vault) <> "?after=1", nil, vault.token) |> body()
    assert Enum.map(tail["records"], & &1["id"]) == [second_id]
    assert tail["cursor"] == 2

    assert body(request(:get, path(vault) <> "?after=2", nil, vault.token)) == %{
             "records" => [],
             "cursor" => 2
           }
  end

  test "vault credentials never authorize access to another vault" do
    alice = new_vault()
    bob = new_vault()
    id = Ecto.UUID.generate()
    assert request(:put, path(alice, id), envelope(81), alice.token).status == 201

    for token <- [nil, bob.token, "invalid"] do
      assert request(:get, path(alice), nil, token).status == 401
      assert request(:get, path(alice, id), nil, token).status == 401
      assert request(:put, path(alice, id), envelope(84), token).status == 401
    end

    assert request(:get, path(bob, id), nil, bob.token).status == 404
  end

  test "the API rejects plaintext, malformed IDs, malformed cursors and oversized records" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    assert request(:put, path(vault, id), "My readable diary", vault.token).status == 400
    assert request(:put, path(vault, "not-a-uuid"), envelope(63), vault.token).status == 400

    assert request(:put, path(vault, id), binary_part(envelope(1), 0, 63), vault.token).status ==
             400

    assert request(:put, path(vault, id), envelope(62, 1024 * 1024 + 1), vault.token).status ==
             413

    for cursor <- ["-1", "1x", "9223372036854775808"] do
      assert request(:get, path(vault) <> "?after=" <> cursor, nil, vault.token).status == 400
    end

    assert body(request(:get, path(vault), nil, vault.token))["records"] == []
  end

  test "a full vault accepts identical retries but not additional storage" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    bytes = envelope(14, 1024 * 1024)
    assert request(:put, path(vault, id), bytes, vault.token).status == 201
    assert request(:put, path(vault, id), bytes, vault.token).status == 200

    assert request(:put, path(vault, Ecto.UUID.generate()), envelope(15), vault.token).status ==
             413

    assert body(request(:get, path(vault), nil, vault.token))["cursor"] == 1
  end

  test "storage failure does not publish a record or consume a sync sequence" do
    vault = new_vault()
    id = Ecto.UUID.generate()
    Process.put(:storage_unavailable, true)
    assert request(:put, path(vault, id), envelope(19), vault.token).status == 503
    assert body(request(:get, path(vault), nil, vault.token))["cursor"] == 0
    Process.delete(:storage_unavailable)
    uploaded = request(:put, path(vault, id), envelope(19), vault.token)
    assert uploaded.status == 201
    assert body(uploaded)["sequence"] == 1
  end

  test "draft compare-and-swap preserves a concurrent writer and does not consume snapshot quota" do
    vault = new_vault()
    path = "/v1/vaults/#{vault.id}/drafts"
    assert request(:get, path, nil, vault.token).status == 404
    assert request(:put, path, envelope(21), vault.token).status == 428
    assert request(:put, path, envelope(21), vault.token, [{"if-none-match", "*"}]).status == 204
    first = request(:get, path, nil, vault.token)
    assert first.resp_body == envelope(21)
    assert get_resp_header(first, "cache-control") == ["no-store"]
    [etag] = get_resp_header(first, "etag")

    assert request(:put, path, envelope(22), vault.token, [{"if-match", etag}]).status == 204
    assert request(:put, path, envelope(23), vault.token, [{"if-match", etag}]).status == 412
    assert request(:put, path, envelope(23), vault.token, [{"if-none-match", "*"}]).status == 412
    assert request(:get, path, nil, vault.token).resp_body == envelope(22)
    # Retrying a PUT whose acknowledgement was lost is harmless.
    assert request(:put, path, envelope(22), vault.token, [{"if-match", etag}]).status == 204
    assert body(request(:get, path(vault), nil, vault.token))["cursor"] == 0
    assert Habibi.Repo.get!(Habibi.Vault, vault.id).bytes == 0

    other = new_vault()

    for token <- [nil, "invalid", other.token] do
      assert request(:get, path, nil, token).status == 401
      assert request(:put, path, envelope(24), token, [{"if-match", etag}]).status == 401
    end

    assert request(:get, path, nil, vault.token, [{"authorization", "Bearer invalid"}]).status ==
             401

    assert request(:put, path, "plaintext", vault.token, [{"if-match", etag}]).status == 400

    assert request(:put, path, envelope(25, 1024 * 1024 + 1), vault.token, [{"if-match", etag}]).status ==
             413

    assert request(:get, path, nil, vault.token).resp_body == envelope(22)
    assert Habibi.Repo.aggregate(Habibi.VaultDraft, :count) == 1
  end

  defp new_vault do
    vault = %{
      id: Ecto.UUID.generate(),
      token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    }

    response = request(:post, "/v1/vaults", %{id: vault.id, token: vault.token})
    assert response.status == 201
    vault
  end

  defp request(method, url, payload, token \\ nil, headers \\ []) do
    {payload, type} =
      if is_map(payload),
        do: {Jason.encode!(payload), "application/json"},
        else: {payload, "application/octet-stream"}

    conn = conn(method, url, payload) |> put_req_header("content-type", type)
    conn = put_req_header(conn, "authorization", "Bearer " <> Process.get(:oauth_token))
    conn = if token, do: put_req_header(conn, "x-habibi-vault-token", token), else: conn

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    HabibiWeb.Endpoint.call(conn, HabibiWeb.Endpoint.init([]))
  end

  defp path(vault), do: "/v1/vaults/#{vault.id}/records"
  defp path(vault, id), do: path(vault) <> "/" <> id
  defp body(conn), do: Jason.decode!(conn.resp_body)

  # The server validates framing only. Authenticating ciphertext belongs to the client.
  defp envelope(byte, size \\ 77), do: "HAB1" <> :binary.copy(<<byte>>, size - 4)
end
