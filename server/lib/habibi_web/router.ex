defmodule HabibiWeb.Router do
  use Phoenix.Router

  scope "/", HabibiWeb do
    get "/health", SyncController, :health
    get "/ready", SyncController, :ready
    post "/v1/vaults", SyncController, :create
    put "/v1/vaults/:vault_id/records/:id", SyncController, :put
    get "/v1/vaults/:vault_id/records", SyncController, :list
    get "/v1/vaults/:vault_id/records/:id", SyncController, :get

    get "/", MarketingController, :home
    get "/:locale", MarketingController, :home
    get "/*path", MarketingController, :not_found
  end
end
