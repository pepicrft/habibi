import Config

database_ssl =
  case System.get_env("DATABASE_CA_CERT") do
    nil ->
      false

    certificate ->
      [
        cacertfile: certificate,
        verify: :verify_peer,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
  end

config :habibi, Habibi.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  ssl: database_ssl

config :habibi,
  dns_cluster_query: System.get_env("DNS_CLUSTER_QUERY") || :ignore,
  storage: Application.get_env(:habibi, :storage, Habibi.Storage),
  bucket: System.get_env("S3_BUCKET", "habibi"),
  allow_registration: config_env() == :test or System.get_env("ALLOW_REGISTRATION") == "true"

config :habibi, Habibi.WaitlistEmail,
  api_key: System.get_env("WAITLIST_EMAIL_API_KEY"),
  from: System.get_env("WAITLIST_EMAIL_FROM"),
  mailbox: if(config_env() != :prod, do: System.get_env("WAITLIST_EMAIL_DIR"))

config :habibi, Habibi.BetaUpdates,
  key_id: System.get_env("ASC_API_KEY_ID"),
  issuer: System.get_env("ASC_API_ISSUER_ID"),
  private_key: System.get_env("ASC_API_KEY_P8_BASE64")

if config_env() != :test do
  config :habibi, Habibi.Subscriptions,
    secret_key: System.get_env("REVENUECAT_SECRET_KEY"),
    apple_key: System.get_env("REVENUECAT_APPLE_KEY"),
    google_key: System.get_env("REVENUECAT_GOOGLE_KEY"),
    allow_sandbox: config_env() != :prod and System.get_env("BILLING_ALLOW_SANDBOX") == "true"
end

{:ok, bind_ip} =
  System.get_env("BIND_IP", if(config_env() == :prod, do: "0.0.0.0", else: "127.0.0.1"))
  |> String.to_charlist()
  |> :inet.parse_address()

config :habibi, HabibiWeb.Endpoint,
  url: [
    host: System.get_env("PHX_HOST", "localhost"),
    scheme: if(config_env() == :prod, do: "https", else: "http"),
    port:
      if(config_env() == :prod, do: 443, else: String.to_integer(System.get_env("PORT", "4000")))
  ],
  http: [ip: bind_ip, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      if(config_env() == :prod,
        do: raise("SECRET_KEY_BASE is required"),
        else: String.duplicate("local-development-only-", 4)
      ),
  server: System.get_env("PHX_SERVER") == "true"

config :ex_aws,
  http_client: ExAws.Request.Req,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
  region: System.get_env("AWS_REGION", "us-east-1"),
  retries: [max_attempts: 2, base_backoff_in_ms: 50, max_backoff_in_ms: 500],
  req_opts: [connect_options: [timeout: 3_000], receive_timeout: 10_000]

if endpoint = System.get_env("S3_ENDPOINT") do
  uri = URI.parse(endpoint)

  if uri.scheme not in ["http", "https"] or is_nil(uri.host) or
       uri.path not in [nil, "", "/"] or not is_nil(uri.query) or not is_nil(uri.userinfo) or
       not is_nil(uri.fragment) do
    raise "S3_ENDPOINT must be an http(s) origin without a path, credentials, or query"
  end

  config :ex_aws, :s3, scheme: uri.scheme <> "://", host: uri.host, port: uri.port
end
