defmodule Habibi.OAuthLocalizationTest do
  use ExUnit.Case, async: true
  alias HabibiWeb.{AuthGettext, AuthLocale}

  setup_all do
    # Synthetic test messages, not shipped translations. Compile the real
    # template against an isolated backend to exercise Gettext and HTML escaping.
    directory = Path.join(System.tmp_dir!(), "habibi-auth-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    messages = Path.join(directory, "ar/LC_MESSAGES")
    File.mkdir_p!(messages)

    File.write!(Path.join(messages, "auth.po"), ~S"""
    msgid ""
    msgstr ""
    "Language: ar\n"
    "Plural-Forms: nplurals=6; plural=(n == 0 ? 0 : n == 1 ? 1 : n == 2 ? 2 : n % 100 >= 3 && n % 100 <= 10 ? 3 : n % 100 >= 11 && n % 100 <= 99 ? 4 : 5);\n"

    msgid "Sign in with a passkey"
    msgstr "TEST sign in <script>alert(1)</script>"

    msgid "Follow your device’s passkey prompt…"
    msgstr "TEST \" onmouseover=\"alert(1) <script>&"

    msgid "%{app} is asking to connect to Habibi. App names are supplied by their developer and are not verified."
    msgstr "TEST %{app} <em>untrusted</em>"
    """)

    Code.compile_quoted(
      quote do
        defmodule Habibi.OAuthLocalizationTest.Gettext do
          use Gettext.Backend, otp_app: :habibi, priv: unquote(directory), default_locale: "en"
        end

        defmodule Habibi.OAuthLocalizationTest.Template do
          use Gettext, backend: Habibi.OAuthLocalizationTest.Gettext
          require EEx

          EEx.function_from_file(
            :def,
            :page,
            unquote(Path.expand("../priv/templates/authorize.html.eex", __DIR__)),
            [:assigns],
            engine: Phoenix.HTML.Engine
          )
        end
      end
    )

    :ok
  end

  test "ships only English in an isolated auth catalogue" do
    assert Gettext.known_locales(AuthGettext) == ["en"]
    assert AuthGettext.__gettext__(:priv) == "priv/auth_gettext"
    assert AuthLocale.select(["ar, fr;q=0.9, en-US;q=0.5"]) == "en"
    assert AuthLocale.select([]) == "en"
  end

  test "negotiates installed locales by quality, order, case and regional fallback" do
    locales = ["en", "fr", "fr_CA", "ar", "zh_Hant"]
    assert AuthLocale.select(["ar;q=0.5, fr-CA;q=0.9, en;q=0.1"], locales) == "fr_CA"
    assert AuthLocale.select(["FR-ca"], locales) == "fr_CA"
    assert AuthLocale.select(["fr-BE, en;q=0.5"], locales) == "fr"
    assert AuthLocale.select(["zh-Hant-TW"], locales) == "zh_Hant"
    assert AuthLocale.select(["ar;q=0.8,fr;q=0.8"], locales) == "ar"
    assert AuthLocale.select(["ar;q=0,fr;q=1."], locales) == "fr"
    assert AuthLocale.select(["ar;q=0.,fr;q=0.001"], locales) == "fr"
    assert AuthLocale.select(["de, ar;q=1.001,fr;q=NaN,*"], locales) == "en"
    assert AuthLocale.select(["fr;q=0.1234,ar;q=-1,en;q=2"], locales) == "en"
    assert AuthLocale.select(["\" onload=\"alert(1)", "AR;q=0.5"], locales) == "ar"
  end

  test "language direction uses language and explicit script, independently of request text" do
    for locale <- ["ar", "ar_EG", "he", "fa", "ur", "az_Arab"] do
      assert AuthLocale.direction(locale) == "rtl"
    end

    for locale <- ["en", "fr_CA", "zh_Hant", "ar_Latn"] do
      assert AuthLocale.direction(locale) == "ltr"
    end

    assert AuthLocale.language_tag("fr_CA") == "fr-CA"
  end

  test "installed translations render as escaped HTML and JS data attributes" do
    backend = Habibi.OAuthLocalizationTest.Gettext
    locale = AuthLocale.select(["ar-EG, en;q=0.8"], Gettext.known_locales(backend))
    assert locale == "ar"

    assigns = %{
      locale: AuthLocale.language_tag(locale),
      direction: AuthLocale.direction(locale),
      client: %{name: "<img src=x onerror=alert(1)>"},
      redirect_uri: "fyi.habibi.test:/callback",
      csrf: "csrf",
      signed_in: false,
      registration: true
    }

    html =
      Gettext.with_locale(backend, locale, fn ->
        apply(Habibi.OAuthLocalizationTest.Template, :page, [assigns])
        |> Phoenix.HTML.safe_to_string()
      end)

    assert html =~ ~s(<html lang="ar" dir="rtl">)
    assert html =~ "TEST sign in &lt;script&gt;alert(1)&lt;/script&gt;"

    assert html =~
             ~s|data-prompt="TEST &quot; onmouseover=&quot;alert(1) &lt;script&gt;&amp;"|

    assert html =~
             "TEST &lt;img src=x onerror=alert(1)&gt; &lt;em&gt;untrusted&lt;/em&gt;"

    refute html =~ "<script>alert(1)</script>"
    refute html =~ "<img src=x"
    # Missing translated entries still use the English source message.
    assert html =~ ~s(data-failure="Sign-in could not be completed. Please try again.")
  end
end
