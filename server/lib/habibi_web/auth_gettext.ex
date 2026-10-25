defmodule HabibiWeb.AuthGettext do
  @moduledoc """
  Gettext backend for the OAuth browser UI, separate from the marketing extractor.

  Auth catalogues live at `priv/auth_gettext/<locale>/LC_MESSAGES/auth.po`.
  Adding or updating a locale requires recompiling the backend. English source
  messages are the fallback for missing translations.
  """
  use Gettext.Backend, otp_app: :habibi, priv: "priv/auth_gettext", default_locale: "en"
end
