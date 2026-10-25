defmodule Habibi.Storage do
  def put(key, ciphertext) do
    bucket()
    |> ExAws.S3.put_object(key, ciphertext, content_type: "application/octet-stream")
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :storage_unavailable}
    end
  end

  def get(key) do
    bucket()
    |> ExAws.S3.get_object(key)
    |> ExAws.request()
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, _} -> {:error, :storage_unavailable}
    end
  end

  defp bucket, do: Application.fetch_env!(:habibi, :bucket)
end
