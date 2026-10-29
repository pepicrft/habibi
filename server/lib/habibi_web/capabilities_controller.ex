defmodule HabibiWeb.CapabilitiesController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    registration = Application.fetch_env!(:habibi, :allow_registration)

    json(conn, %{
      version: 1,
      authentication: %{passkeys: true, phone: false, accountRegistration: registration},
      oauth: %{dynamicClientRegistration: registration},
      subscriptions: %{
        available: Habibi.Subscriptions.available?(),
        entitlement: "plus",
        products: Habibi.Subscriptions.products(),
        requiredFor: ["syncWrites", "draftHandoff"]
      },
      sync: %{
        encryptedSnapshots: true,
        vaultCreation: registration,
        locks: %{
          version: 1,
          leaseSeconds: Habibi.Locks.lease_seconds(),
          maxPerVault: Habibi.Locks.max_per_vault(),
          fencedRecordPut: true
        }
      },
      themes: %{catalog: "/assets/themes.json"}
    })
  end
end
