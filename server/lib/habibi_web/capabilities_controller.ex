defmodule HabibiWeb.CapabilitiesController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    registration = Application.fetch_env!(:habibi, :allow_registration)

    json(conn, %{
      version: 1,
      authentication: %{passkeys: true, phone: false, accountRegistration: registration},
      oauth: %{dynamicClientRegistration: registration},
      sync: %{encryptedSnapshots: true, vaultCreation: registration},
      themes: %{catalog: "/assets/themes.json"}
    })
  end
end
