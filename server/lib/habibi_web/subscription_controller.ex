defmodule HabibiWeb.SubscriptionController do
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  plug HabibiWeb.AuthRateLimit
  plug :authenticate

  def show(conn, _) do
    respond(conn, Habibi.Subscriptions.status(conn.assigns.account.sub))
  end

  def receipt(conn, params) do
    # The authenticated subject, never a posted customer ID, owns the purchase.
    respond(conn, Habibi.Subscriptions.receipt(conn.assigns.account.sub, params))
  end

  defp respond(conn, {:ok, status}),
    do: json(conn, Map.put(status, :available, Habibi.Subscriptions.available?()))

  defp respond(conn, {:error, reason}) do
    conn
    |> put_status(if(reason == :invalid_receipt, do: 422, else: 503))
    |> json(%{error: Atom.to_string(reason)})
  end

  defp authenticate(conn, _) do
    case Habibi.OAuth.authenticate(conn) do
      {:ok, account} -> assign(conn, :account, account)
      _ -> conn |> put_status(401) |> json(%{error: "invalid_token"}) |> halt()
    end
  end
end
