ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Habibi.Repo, :manual)

defmodule Habibi.TestStorage do
  def put(key, bytes) do
    if Process.get(:storage_unavailable) do
      {:error, :storage_unavailable}
    else
      Process.put({__MODULE__, key}, bytes)
      :ok
    end
  end

  def get(key) do
    case Process.get({__MODULE__, key}) do
      nil -> {:error, :storage_unavailable}
      bytes -> {:ok, bytes}
    end
  end
end
