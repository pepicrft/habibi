defmodule Habibi.Subscriptions do
  @moduledoc "Store-verified Plus access. Billing sees account IDs and receipts, never vault data."

  @products ["habibi_plus_monthly", "habibi_plus_yearly"]
  def products, do: @products

  def available? do
    config = Application.get_env(:habibi, __MODULE__, [])
    Enum.all?([:secret_key, :apple_key, :google_key], &present?(config[&1]))
  end

  def status(account) do
    request(:get, "/subscribers/" <> URI.encode_www_form(account), :secret_key)
  end

  def receipt(account, %{"platform" => platform, "product_id" => product, "fetch_token" => token})
      when platform in ["ios", "android"] and product in @products and is_binary(token) and
             byte_size(token) in 1..65_536 do
    request(:post, "/receipts", if(platform == "ios", do: :apple_key, else: :google_key),
      headers: [{"x-platform", platform}],
      json: %{app_user_id: account, product_id: product, fetch_token: token}
    )
  end

  def receipt(_, _), do: {:error, :invalid_receipt}

  defp request(method, path, key, options \\ []) do
    config = Application.get_env(:habibi, __MODULE__, [])

    if present?(config[key]) do
      options =
        Keyword.merge(
          [
            method: method,
            url: "https://api.revenuecat.com/v1" <> path,
            auth: {:bearer, config[key]},
            retry: false,
            redirect: false,
            receive_timeout: 5_000,
            connect_options: [timeout: 3_000]
          ] ++ Keyword.get(config, :request_options, []),
          options
        )

      case Req.request(options) do
        {:ok, %{status: 200, body: %{"subscriber" => subscriber}}} ->
          access(subscriber)

        {:ok, %{status: 404}} when method == :get ->
          {:ok, free()}

        {:ok, %{status: status}} when method == :post and status in [400, 409, 422] ->
          {:error, :invalid_receipt}

        _ ->
          {:error, :billing_unavailable}
      end
    else
      {:error, :billing_unavailable}
    end
  end

  defp access(%{"entitlements" => entitlements, "subscriptions" => subscriptions})
       when is_map(entitlements) and is_map(subscriptions) do
    with %{"product_identifier" => product} = entitlement <- entitlements["plus"],
         true <- product in @products,
         %{} = subscription <- subscriptions[product],
         true <- subscription["refunded_at"] == nil,
         true <- subscription["is_sandbox"] == false or sandbox?(),
         date when is_binary(date) <- entitlement["expires_date"],
         {:ok, expires, _} <- DateTime.from_iso8601(date),
         {:ok, until} <- grace_until(expires, entitlement["grace_period_expires_date"]),
         :gt <- DateTime.compare(until, DateTime.utc_now()) do
      {:ok, %{plan: "plus", active: true, expires_at: DateTime.to_iso8601(until)}}
    else
      _ -> {:ok, free()}
    end
  end

  defp access(_), do: {:error, :billing_unavailable}
  defp grace_until(expires, nil), do: {:ok, expires}

  defp grace_until(expires, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, grace, _} -> {:ok, Enum.max_by([expires, grace], &DateTime.to_unix(&1, :microsecond))}
      _ -> {:error, :invalid_date}
    end
  end

  defp grace_until(_, _), do: {:error, :invalid_date}
  defp sandbox?, do: Application.get_env(:habibi, __MODULE__, [])[:allow_sandbox] == true
  defp present?(value), do: is_binary(value) and byte_size(value) > 0
  defp free, do: %{plan: "free", active: false, expires_at: nil}
end
