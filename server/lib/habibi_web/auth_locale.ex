defmodule HabibiWeb.AuthLocale do
  @moduledoc """
  Negotiates only compiled auth locales, without converting request data to atoms.

  Language ranges are matched case-insensitively, by quality and then header
  order, with regional tags falling back to their parent language. Unsupported,
  malformed and wildcard-only preferences fall back to English.
  """

  @language_range ~r/\A\s*([a-zA-Z]{1,8}(?:-[a-zA-Z0-9]{1,8})*)(?:\s*;\s*q=(0(?:\.\d{0,3})?|1(?:\.0{0,3})?))?\s*\z/
  @rtl_languages ~w(ar ckb dv fa he ps sd syr ug ur yi)
  @rtl_scripts ~w(adlm arab hebr mand nkoo rohg syrc thaa)

  def select(headers, locales \\ Gettext.known_locales(HabibiWeb.AuthGettext)) do
    installed = Map.new(locales, &{normalize(&1), &1})

    headers
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&preference/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_, quality} -> -quality end)
    |> Enum.find_value("en", fn {range, _} -> match_locale(range, installed) end)
  end

  def language_tag(locale), do: String.replace(locale, "_", "-")

  def direction(locale) do
    [language | subtags] = locale |> normalize() |> String.split("-")
    script = Enum.find(subtags, &(byte_size(&1) == 4))

    rtl? = if script, do: script in @rtl_scripts, else: language in @rtl_languages
    if rtl?, do: "rtl", else: "ltr"
  end

  defp preference(value) do
    case Regex.run(@language_range, value) do
      [_, range] ->
        {normalize(range), 1.0}

      [_, range, quality] ->
        {quality, _} = Float.parse(quality)
        if quality > 0, do: {normalize(range), quality}

      _ ->
        nil
    end
  end

  defp match_locale(range, installed) do
    case Map.fetch(installed, range) do
      {:ok, locale} ->
        locale

      :error ->
        case String.split(range, "-") |> Enum.drop(-1) do
          [] -> nil
          parent -> match_locale(Enum.join(parent, "-"), installed)
        end
    end
  end

  defp normalize(locale), do: locale |> language_tag() |> String.downcase()
end
