import Config

config :habibi,
  ecto_repos: [Habibi.Repo],
  max_vault_bytes: 100 * 1024 * 1024,
  max_vault_records: 10_000

config :habibi, HabibiWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: HabibiWeb.Errors], layout: false, log: false],
  pubsub_server: Habibi.PubSub,
  server: false

config :phoenix, :json_library, Jason
config :phoenix, :logger, false
config :phoenix, :filter_parameters, {:keep, []}
config :habibi, Habibi.Repo, log: false
config :logger, level: :info

if config_env() == :test do
  config :habibi, :allow_registration, true
  config :habibi, :storage, Habibi.TestStorage
  config :habibi, :max_vault_bytes, 1024 * 1024

  config :habibi, Habibi.Repo,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10
end
