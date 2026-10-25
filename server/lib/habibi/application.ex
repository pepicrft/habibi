defmodule Habibi.Application do
  use Application

  def start(_type, _args) do
    children = [
      Habibi.Repo,
      {Phoenix.PubSub, name: Habibi.PubSub},
      {DNSCluster, query: Application.fetch_env!(:habibi, :dns_cluster_query)},
      HabibiWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Habibi.Supervisor)
  end
end
