defmodule HabibiWeb.AuthRateLimit do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Use the socket peer, not an untrusted X-Forwarded-For header. Behind ingress,
    # replicas may share a conservative limit rather than accepting spoofed IPs.
    key = :crypto.hash(:sha256, :erlang.term_to_binary({conn.remote_ip, conn.path_info}))

    sql = """
    INSERT INTO auth_rate_limits (id, count, expires_at) VALUES ($1, 1, now() + interval '1 minute')
    ON CONFLICT (id) DO UPDATE SET
      count = CASE WHEN auth_rate_limits.expires_at <= now() THEN 1 ELSE auth_rate_limits.count + 1 END,
      expires_at = CASE WHEN auth_rate_limits.expires_at <= now() THEN now() + interval '1 minute' ELSE auth_rate_limits.expires_at END
    RETURNING count
    """

    Ecto.Adapters.SQL.query!(
      Habibi.Repo,
      "DELETE FROM auth_rate_limits WHERE expires_at < now() - interval '1 hour'",
      []
    )

    case Ecto.Adapters.SQL.query!(Habibi.Repo, sql, [key]).rows do
      [[count]] when count <= 60 ->
        conn

      _ ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()
    end
  end
end
