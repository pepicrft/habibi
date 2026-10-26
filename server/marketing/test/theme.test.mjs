import { test } from "node:test";
import assert from "node:assert/strict";
import { css } from "@theme-ui/css";
import { nativeThemes, readNativeThemes, readTheme, readThemeVariants } from "../theme.mjs";

const roles = [
  "primary", "background", "text", "textMuted", "accent", "muted",
  "border", "secondary", "focus", "memoryBorder", "bubble", "surface", "onPrimary",
];

function luminance(hex) {
  const [red, green, blue] = hex.slice(1).match(/../g).map((channel) => {
    const value = Number.parseInt(channel, 16) / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

function contrast(first, second) {
  const values = [luminance(first), luminance(second)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

test("the native catalog uses complete Theme UI light/dark palettes with accessible semantic pairs", () => {
  const catalog = readNativeThemes();
  assert.equal(catalog.version, 1);
  assert.equal(catalog.defaultTheme, "forest");
  assert.deepEqual(catalog.themes.map(({ id, name }) => [id, name]), [
    ["forest", "Forest"], ["clay", "Clay"], ["lavender", "Lavender"],
  ]);
  const primaryColors = new Set();
  const backgrounds = new Set();
  for (const theme of catalog.themes) {
    assert.deepEqual(Object.keys(theme.colors.modes), ["dark"]);
    const { modes, ...light } = theme.colors;
    assert.notDeepEqual(light, modes.dark);
    for (const colors of [light, modes.dark]) {
      assert.deepEqual(Object.keys(colors).sort(), [...roles].sort());
      for (const [role, color] of Object.entries(colors)) {
        assert.match(color, /^#[0-9a-f]{6}$/i, `${theme.id}.${role}`);
      }
      primaryColors.add(colors.primary);
      backgrounds.add(colors.background);
      for (const background of ["background", "surface", "muted", "bubble"]) {
        for (const foreground of ["text", "textMuted"]) {
          assert.ok(
            contrast(colors[foreground], colors[background]) >= 4.5,
            `${theme.id}: ${foreground} on ${background} must meet WCAG AA`,
          );
        }
      }
      assert.ok(contrast(colors.text, colors.accent) >= 4.5);
      assert.ok(contrast(colors.onPrimary, colors.primary) >= 4.5);
      assert.ok(contrast(colors.onPrimary, colors.secondary) >= 4.5);
      assert.ok(contrast(colors.primary, colors.background) >= 4.5);
      assert.ok(contrast(colors.focus, colors.background) >= 3);
      // The emitted objects remain directly consumable by Theme UI's resolver.
      assert.deepEqual(css({ color: "text", bg: "background" })({ ...theme, colors }), {
        color: colors.text,
        backgroundColor: colors.background,
      });
    }
  }
  assert.equal(primaryColors.size, 6);
  assert.equal(backgrounds.size, 6);
});

test("Forest inherits base light values and every theme inherits ordinary Theme UI tokens without mutation", () => {
  const base = readTheme();
  const variants = readThemeVariants();
  const original = structuredClone({ base, variants });
  const catalog = nativeThemes(base, variants);
  const forest = catalog.themes.find(({ id }) => id === catalog.defaultTheme);
  // No copied default light values may accumulate in the descriptor file.
  assert.deepEqual(Object.keys(variants.themes[0].colors), ["modes"]);
  for (const [role, value] of Object.entries(base.colors)) {
    assert.equal(forest.colors[role], value);
  }
  for (const theme of catalog.themes) {
    for (const key of Object.keys(base).filter((key) => key !== "colors")) {
      assert.deepEqual(theme[key], base[key]);
    }
    assert.equal(theme.colors.surface, theme.colors.background);
    assert.equal(theme.colors.modes.dark.surface, theme.colors.modes.dark.background);
    assert.deepEqual(css({ variant: "buttons.primary" })(theme), {
      color: theme.colors.background,
      backgroundColor: theme.colors.primary,
      fontWeight: base.fontWeights.button,
      "&:hover": {
        color: theme.colors.background,
        backgroundColor: theme.colors.secondary,
      },
    });
  }
  assert.deepEqual({ base, variants }, original);

  base.colors.primary = "#456789";
  base.colors.background = "#fefdfa";
  base.fonts.body = "system-ui";
  base.space[6] = 29;
  const changed = nativeThemes(base, variants);
  assert.equal(changed.themes[0].colors.primary, "#456789");
  assert.equal(changed.themes[0].colors.surface, "#fefdfa");
  assert.equal(changed.themes[0].colors.onPrimary, "#fefdfa");
  for (const theme of changed.themes) {
    assert.equal(theme.fonts.body, "system-ui");
    assert.equal(theme.space[6], 29);
  }
  assert.equal(changed.themes[1].colors.primary, variants.themes[1].colors.primary);
  assert.equal(changed.themes[0].colors.modes.dark.primary, variants.themes[0].colors.modes.dark.primary);
});
