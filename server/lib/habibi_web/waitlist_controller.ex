defmodule HabibiWeb.WaitlistController do
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  alias Habibi.Waitlist

  def status(conn, _params) do
    conn
    |> put_resp_header("x-robots-tag", "noindex")
    |> json(%{
      csrf: Plug.CSRFProtection.get_csrf_token(),
      origin: HabibiWeb.Endpoint.url(),
      entry: Waitlist.status(get_session(conn, :waitlist_id))
    })
  end

  def join(conn, %{"email" => email} = params) do
    if params["website"] not in [nil, ""] do
      conn |> put_status(202) |> json(%{status: "check_email"})
    else
      case Waitlist.request_access(email, params["ref"]) do
        {:ok, :ok} ->
          conn |> put_status(202) |> json(%{status: "check_email"})

        {:error, :invalid_email} ->
          conn |> put_status(422) |> json(%{error: "invalid_email"})

        {:error, :delivery_unavailable} ->
          conn |> put_status(503) |> json(%{error: "delivery_unavailable"})
      end
    end
  end

  def join(conn, _params), do: conn |> put_status(422) |> json(%{error: "invalid_email"})

  def confirm(conn, params) do
    case Waitlist.confirm(params["token"]) do
      {:ok, id} ->
        conn |> configure_session(renew: true) |> put_session(:waitlist_id, id) |> status(%{})

      {:error, :invalid_token} ->
        conn |> put_status(422) |> json(%{error: "invalid_token"})
    end
  end

  def leave(conn, _params) do
    if id = get_session(conn, :waitlist_id) do
      Waitlist.leave(id)
      conn |> delete_session(:waitlist_id) |> json(%{status: "deleted"})
    else
      conn |> put_status(401) |> json(%{error: "confirmation_required"})
    end
  end
end
