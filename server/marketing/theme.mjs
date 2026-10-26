import { readFileSync } from "node:fs";
import { css } from "@theme-ui/css";
import { serializeStyles } from "@emotion/serialize";
import { compile, serialize, stringify } from "stylis";

export const themePath = new URL("../priv/theme.json", import.meta.url);
export const readTheme = () => JSON.parse(readFileSync(themePath, "utf8"));
export const themeVariantsPath = new URL("../priv/theme-variants.json", import.meta.url);
export const readThemeVariants = () =>
  JSON.parse(readFileSync(themeVariantsPath, "utf8"));

// Each entry is an ordinary Theme UI theme, with stable selection metadata.
// Forest inherits every light token from theme.json; descriptors only override
// colors, so shared typography, spacing and component variants cannot drift.
export function nativeThemes(theme, variants) {
  const palette = (colors) => ({
    surface: colors.background,
    onPrimary: colors.background,
    ...colors,
  });
  return {
    version: 1,
    defaultTheme: variants.defaultTheme,
    themes: variants.themes.map(({ id, name, colors }) => ({
      ...theme,
      id,
      name,
      colors: {
        ...palette({ ...theme.colors, ...colors }),
        modes: { dark: palette(colors.modes.dark) },
      },
    })),
  };
}

// Shared by the public asset build and native offline resource preparation.
export const readNativeThemes = () => nativeThemes(readTheme(), readThemeVariants());

// NSH consumes shadcn-style cssVars, not React context or Theme UI's sx prop.
// Map semantic roles rather than assuming similarly named tokens mean the same.
export function nshTheme(theme) {
  const { colors, fonts, radii } = theme;
  return {
    cssVars: {
      theme: {
        radius: `${radii.control}px`,
        "font-sans": fonts.body,
        "font-mono": fonts.monospace,
        ...Object.fromEntries(
          theme.space.map((value, index) => [`space-${index}`, `${value}px`]),
        ),
      },
      light: {
        background: colors.background,
        foreground: colors.text,
        card: colors.background,
        "card-foreground": colors.text,
        popover: colors.background,
        "popover-foreground": colors.text,
        primary: colors.primary,
        "primary-foreground": colors.background,
        secondary: colors.muted,
        "secondary-foreground": colors.text,
        muted: colors.muted,
        "muted-foreground": colors.textMuted,
        accent: colors.accent,
        "accent-foreground": colors.secondary,
        border: colors.border,
        input: colors.border,
        ring: colors.focus,
      },
    },
  };
}

// Use Theme UI's scale/variant resolver for the non-React, server-rendered UIs.
// Layout stays in each UI's stylesheet; design values live only in theme.json.
export function themeCSS(theme) {
  const scales = {
    colors: "color",
    fonts: "fontFamily",
    fontSizes: "fontSize",
    fontWeights: "fontWeight",
    lineHeights: "lineHeight",
    space: "padding",
    radii: "borderRadius",
    borderWidths: "borderWidth",
  };
  const unitless = new Set(["fontWeights", "lineHeights"]);
  const variables = Object.entries(scales).flatMap(([scale, property]) =>
    Object.keys(theme[scale]).map((key) => {
      const reference = Array.isArray(theme[scale]) ? Number(key) : key;
      const value = css({ [property]: reference })(theme)[property];
      const unit =
        typeof value === "number" && !unitless.has(scale) ? "px" : "";
      return `--theme-ui-${scale}-${key}:${value}${unit};`;
    }),
  );
  const rule = (selector, styles) =>
    serialize(
      compile(`${selector}{${serializeStyles([styles]).styles}}`),
      stringify,
    );

  return [
    "/* Generated from server/priv/theme.json. Do not edit. */",
    ...theme.fontFaces.map((face) => rule("@font-face", face)),
    `:root{${variables.join("")}}`,
    rule(":root", css({ variant: "styles.root" })(theme)),
    rule(".button-primary", css({ variant: "buttons.primary" })(theme)),
  ].join("\n");
}
