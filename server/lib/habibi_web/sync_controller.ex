defmodule HabibiWeb.SyncController do
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias Habibi.Sync

  plug :authenticate_account when action in [:create, :put, :list, :get]
  plug :authorize when action in [:put, :list, :get]

  def health(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    case Ecto.Adapters.SQL.query(
           Habibi.Repo,
           "SELECT to_regclass('public.vaults') IS NOT NULL AND to_regclass('public.records') IS NOT NULL AND to_regclass('public.passkeys') IS NOT NULL AND to_regclass('public.oauth_grants') IS NOT NULL",
           [],
           timeout: 2_000
         ) do
      {:ok, %{rows: [[true]]}} -> json(conn, %{status: "ready"})
      _ -> conn |> put_status(503) |> json(%{status: "not_ready"})
    end
  end

  def create(conn, params) do
    if Application.fetch_env!(:habibi, :allow_registration) do
      case Sync.create_vault(params["id"], params["token"]) do
        {:ok, vault} -> conn |> put_status(201) |> json(%{id: vault.id})
        {:error, reason} -> error(conn, reason)
      end
    else
      conn |> put_status(403) |> json(%{error: "registration_disabled"})
    end
  end

  def put(conn, %{"id" => id}) do
    max_bytes = Sync.max_record_bytes()

    if get_req_header(conn, "content-type") == ["application/octet-stream"] do
      case read_body(conn,
             length: max_bytes + 1,
             read_length: max_bytes + 1
           ) do
        {:ok, body, conn} when byte_size(body) > max_bytes ->
          conn |> put_status(413) |> json(%{error: "record_too_large"})

        {:ok, body, conn} ->
          case Sync.put(conn.assigns.vault, id, body) do
            {:ok, {record, mode}} ->
              conn
              |> put_status(if(mode == :created, do: 201, else: 200))
              |> json(metadata(record))

            {:error, reason} ->
              error(conn, reason)
          end

        {:more, _body, conn} ->
          conn |> put_status(413) |> json(%{error: "record_too_large"})

        {:error, _} ->
          error(conn, :invalid_envelope)
      end
    else
      conn |> put_status(415) |> json(%{error: "expected_octet_stream"})
    end
  end

  def list(conn, params) do
    with cursor when is_binary(cursor) <- params["after"] || "0",
         {cursor, ""} <- Integer.parse(cursor),
         true <- cursor >= 0 and cursor <= 9_223_372_036_854_775_807 do
      records = Sync.list(conn.assigns.vault, cursor)
      next_cursor = if records == [], do: cursor, else: List.last(records).sequence
      json(conn, %{records: Enum.map(records, &metadata/1), cursor: next_cursor})
    else
      _ -> error(conn, :invalid_cursor)
    end
  end

  def get(conn, %{"id" => id}) do
    case Sync.get(conn.assigns.vault, id) do
      {:ok, ciphertext} ->
        conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, ciphertext)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp authorize(conn, _opts) do
    with [token] <- get_req_header(conn, "x-habibi-vault-token"),
         {:ok, vault} <- Sync.authorize(conn.path_params["vault_id"], token) do
      assign(conn, :vault, vault)
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end

  defp authenticate_account(conn, _opts) do
    case Habibi.OAuth.authenticate(conn) do
      {:ok, owner} ->
        assign(conn, :account, owner)

      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="habibi"))
        |> put_status(401)
        |> json(%{error: "invalid_token"})
        |> halt()
    end
  end

  defp metadata(record) do
    %{id: record.id, sequence: record.sequence, bytes: record.bytes, sha256: record.digest}
  end

  defp error(conn, reason) do
    status =
      case reason do
        :conflict -> 409
        :quota_exceeded -> 413
        :not_found -> 404
        :storage_unavailable -> 503
        _ -> 400
      end

    conn |> put_status(status) |> json(%{error: Atom.to_string(reason)})
  end
end
