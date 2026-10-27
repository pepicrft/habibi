defmodule HabibiWeb.Router do
  use Phoenix.Router

  pipeline :auth_api do
    plug HabibiWeb.AuthRateLimit
  end

  pipeline :auth_browser do
    plug :fetch_session
    plug Plug.CSRFProtection
    plug HabibiWeb.AuthRateLimit
  end

  scope "/", HabibiWeb do
    get "/.well-known/oauth-authorization-server", OAuthController, :metadata
    get "/v1/capabilities", CapabilitiesController, :show
    get "/v1/me", OAuthController, :me
  end

  scope "/oauth", HabibiWeb do
    pipe_through :auth_api
    post "/register", OAuthController, :register
    post "/token", OAuthController, :token
    post "/revoke", OAuthController, :revoke
  end

  scope "/", HabibiWeb do
    pipe_through :auth_browser
    get "/oauth/authorize", OAuthController, :authorize
    post "/oauth/authorize", OAuthController, :consent
    post "/auth/passkeys/options", OAuthController, :passkey_options
    post "/auth/passkeys/finish", OAuthController, :passkey_finish
    post "/auth/logout", OAuthController, :logout
  end

  scope "/", HabibiWeb do
    get "/health", SyncController, :health
    get "/ready", SyncController, :ready
    post "/v1/vaults", SyncController, :create
    put "/v1/vaults/:vault_id/records/:id", SyncController, :put
    get "/v1/vaults/:vault_id/records", SyncController, :list
    get "/v1/vaults/:vault_id/records/:id", SyncController, :get
    put "/v1/vaults/:vault_id/locks/:id", SyncController, :acquire_lock
    post "/v1/vaults/:vault_id/locks/:id/renew", SyncController, :renew_lock
    delete "/v1/vaults/:vault_id/locks/:id", SyncController, :release_lock

    get "/", MarketingController, :home
    get "/changelog", MarketingController, :changelog
    get "/:locale/changelog", MarketingController, :changelog
    get "/:locale", MarketingController, :home
    get "/*path", MarketingController, :not_found
  end
end
