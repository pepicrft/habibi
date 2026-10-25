import { test } from "node:test";
import assert from "node:assert/strict";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
  appendFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

test("the public marketing build localizes routes and metadata, escapes translations and detects stale extraction", () => {
  const root = fileURLToPath(new URL("../../../", import.meta.url));
  const fixture = mkdtempSync(join(tmpdir(), "habibi-marketing-"));
  try {
    const marketing = join(fixture, "server/marketing");
    cpSync(join(root, "server/marketing"), marketing, {
      recursive: true,
      filter: (path) => !path.includes("node_modules"),
    });
    cpSync(
      join(root, "server/priv/gettext"),
      join(fixture, "server/priv/gettext"),
      { recursive: true },
    );
    cpSync(
      join(root, "server/priv/theme.json"),
      join(fixture, "server/priv/theme.json"),
    );
    mkdirSync(join(fixture, "client"));
    cpSync(join(root, "client/theme.mjs"), join(fixture, "client/theme.mjs"));
    symlinkSync(
      join(root, "node_modules"),
      join(fixture, "node_modules"),
      "dir",
    );
    const spanish =
      'msgid ""\nmsgstr ""\n"Language: es\\n"\n"Content-Type: text/plain; charset=UTF-8\\n"\n\nmsgid "About"\nmsgstr "Acerca <script>alert(1)</script>"\n\n#, fuzzy\nmsgid "Where things stand."\nmsgstr "UNREVIEWED"\n';
    for (const [locale, po] of [
      ["es", spanish],
      ["ar", spanish.replace("Language: es", "Language: ar")],
    ]) {
      const directory = join(
        fixture,
        "server/priv/gettext",
        locale,
        "LC_MESSAGES",
      );
      mkdirSync(directory, { recursive: true });
      writeFileSync(join(directory, "marketing.po"), po);
    }
    const run = (...args) =>
      execFileSync(process.execPath, args, { cwd: marketing, stdio: "pipe" });
    run("gettext.mjs", "--check");
    run(join(root, "node_modules/@11ty/eleventy/cmd.cjs"));
    const output = join(fixture, "server/priv/static/marketing");
    const english = readFileSync(join(output, "index.html"), "utf8");
    const localized = readFileSync(join(output, "es/index.html"), "utf8");
    assert.match(english, /<html lang="en" dir="ltr">/);
    assert.match(localized, /<html lang="es" dir="ltr">/);
    assert.ok(
      localized.includes("Acerca &lt;script&gt;alert(1)&lt;/script&gt;"),
    );
    assert.ok(!localized.includes("<script>"));
    assert.ok(!localized.includes("UNREVIEWED"));
    assert.ok(localized.includes("Where things stand."));
    assert.ok(localized.includes('href="/es/#privacy"'));
    assert.ok(
      localized.includes('rel="canonical" href="https://habibi.fyi/es/"'),
    );
    assert.ok(localized.includes('href="/assets/styles.css"'));
    assert.ok(localized.includes('href="/assets/theme.css"'));
    assert.deepEqual(
      JSON.parse(readFileSync(join(output, "assets/theme.json"))),
      JSON.parse(readFileSync(join(fixture, "server/priv/theme.json"))),
    );
    // The native-ready frame map must describe the shipped atlas, not CSS geometry.
    const mascotDirectory = join(output, "assets/mascot");
    const mascot = JSON.parse(
      readFileSync(join(mascotDirectory, "heartling.json")),
    );
    const atlas = readFileSync(join(mascotDirectory, mascot.image));
    const poster = readFileSync(join(mascotDirectory, mascot.poster));
    assert.equal(atlas.readUInt32BE(16), mascot.width);
    assert.equal(atlas.readUInt32BE(20), mascot.height);
    assert.equal(atlas[25], 4); // PNG grayscale + real alpha, not a baked backdrop.
    assert.equal(poster.readUInt32BE(16), mascot.frameWidth);
    assert.equal(poster.readUInt32BE(20), mascot.frameHeight);
    assert.equal(mascot.width, mascot.columns * mascot.frameWidth);
    assert.equal(mascot.height % mascot.frameHeight, 0);
    assert.equal(mascot.tintToken, "primary");
    assert.equal(mascot.blendMode, "hard-light");
    for (const state of Object.values(mascot.states)) {
      for (const frame of state.frames) {
        assert.ok(Number.isInteger(frame) && frame >= 0);
        assert.ok(
          frame < (mascot.columns * mascot.height) / mascot.frameHeight,
        );
      }
    }
    assert.equal(mascot.states.idle.frames.length, 1);
    assert.equal(mascot.states.walk.frames.length, 4);
    assert.ok(mascot.states.walk.frameDurationMs > 0);
    assert.match(
      readFileSync(join(output, "ar/index.html"), "utf8"),
      /<html lang="ar" dir="rtl">/,
    );
    assert.ok(
      readFileSync(join(output, "es/404.html"), "utf8").includes('href="/es/"'),
    );
    assert.ok(
      readFileSync(join(output, "sitemap.xml"), "utf8").includes(
        "https://habibi.fyi/es/",
      ),
    );
    assert.deepEqual(JSON.parse(readFileSync(join(output, "locales.json"))), [
      "ar",
      "en",
      "es",
    ]);

    appendFileSync(
      join(marketing, "site/index.njk"),
      '\n{{ dgettext("marketing", "Newly added copy") }}\n',
    );
    assert.throws(() => run("gettext.mjs", "--check"), /out of date/);
    run("gettext.mjs");
    run("gettext.mjs", "--check");
    assert.ok(
      readFileSync(
        join(fixture, "server/priv/gettext/marketing.pot"),
        "utf8",
      ).includes("Newly added copy"),
    );
    assert.equal(
      readFileSync(
        join(fixture, "server/priv/gettext/es/LC_MESSAGES/marketing.po"),
        "utf8",
      ),
      spanish,
    );

    for (const locale of ["ar", "es"]) {
      rmSync(join(fixture, "server/priv/gettext", locale), { recursive: true });
    }
    // A server token edit must reach web assets, metadata and the bundled client.
    // Distinct colors and non-default scale values catch raw-key/index mistakes.
    const theme = JSON.parse(
      readFileSync(join(fixture, "server/priv/theme.json")),
    );
    theme.colors.primary = "#a13265";
    theme.colors.secondary = "#1e5460";
    theme.colors.background = "#ecf5e1";
    theme.fonts.body = "system-ui";
    theme.space[6] = 27;
    theme.lineHeights.body = 1.73;
    theme.fontWeights.button = 625;
    writeFileSync(
      join(fixture, "server/priv/theme.json"),
      JSON.stringify(theme),
    );
    execFileSync("npm", ["run", "build"], { cwd: marketing, stdio: "pipe" });
    const css = readFileSync(join(output, "assets/theme.css"), "utf8");
    assert.match(css, /--theme-ui-space-6:27px;/);
    assert.match(css, /--theme-ui-lineHeights-body:1\.73;/);
    assert.match(css, /--theme-ui-fonts-body:system-ui;/);
    assert.match(
      css,
      /\.button-primary\{[^}]*background-color:#a13265;[^}]*font-weight:625;/,
    );
    assert.match(css, /\.button-primary:hover\{[^}]*background-color:#1e5460;/);
    const favicon = readFileSync(join(output, "assets/favicon.svg"), "utf8");
    assert.match(favicon, /fill="#a13265"/);
    assert.match(favicon, /fill="#ecf5e1"/);
    const social = readFileSync(join(output, "assets/social.svg"), "utf8");
    assert.match(social, /fill="#ecf5e1"/);
    assert.match(social, /font-family="system-ui"/);
    assert.ok(
      readFileSync(join(output, "index.html"), "utf8").includes(
        '<meta name="theme-color" content="#ecf5e1">',
      ),
    );
    const clientTheme = execFileSync(
      process.execPath,
      [
        "--input-type=module",
        "-e",
        'import theme from "./client/theme.mjs"; process.stdout.write(JSON.stringify(theme));',
      ],
      { cwd: fixture, encoding: "utf8" },
    );
    assert.deepEqual(
      JSON.parse(clientTheme),
      JSON.parse(readFileSync(join(output, "assets/theme.json"))),
    );
    const nativeTheme = JSON.parse(
      readFileSync(join(output, "assets/nsh-theme.json")),
    );
    assert.equal(nativeTheme.cssVars.light[mascot.tintToken], "#a13265");
    assert.equal(nativeTheme.cssVars.light.background, "#ecf5e1");
    assert.equal(nativeTheme.cssVars.light.foreground, theme.colors.text);
    assert.equal(nativeTheme.cssVars.light.secondary, theme.colors.muted);
    assert.equal(nativeTheme.cssVars.theme["space-6"], "27px");
    assert.equal(nativeTheme.cssVars.theme["font-sans"], "system-ui");
    assert.deepEqual(JSON.parse(readFileSync(join(output, "locales.json"))), [
      "en",
    ]);
    assert.ok(!existsSync(join(output, "es/index.html")));
    assert.ok(!existsSync(join(output, "ar/index.html")));
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
