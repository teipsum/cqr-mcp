defmodule CqrMcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Cqr.Grafeo.Server, storage: :memory},
      Cqr.Repo.ScopeTree
    ]

    opts = [strategy: :one_for_one, name: CqrMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
