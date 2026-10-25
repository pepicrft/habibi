defmodule Habibi.Release do
  @moduledoc "Database migrations run by a separate release job, never by web replicas."

  def migrate do
    Application.load(:habibi)

    for repo <- Application.fetch_env!(:habibi, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
