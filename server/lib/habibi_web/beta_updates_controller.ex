defmodule HabibiWeb.BetaUpdatesController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    case Habibi.BetaUpdates.latest() do
      {:ok, metadata} ->
        json(conn, metadata)

      {:error, :updates_unavailable} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "updates_unavailable"})
    end
  end
end
