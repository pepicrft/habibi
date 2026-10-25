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
    symlinkSync(
      join(root, "node_modules"),
      join(fixture, "node_modules"),
      "dir",
    );
    const spanish =
      'msgid ""\nmsgstr ""\n"Language: es\\n"\n"Content-Type: text/plain; charset=UTF-8\\n"\n\nmsgid "About"\nmsgstr "Acerca <script>alert(1)</script>"\n\n#, fuzzy\nmsgid "Good to know."\nmsgstr "UNREVIEWED"\n';
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
    assert.ok(localized.includes("Good to know."));
    assert.ok(localized.includes('href="/es/#privacy"'));
    assert.ok(
      localized.includes('rel="canonical" href="https://habibi.fyi/es/"'),
    );
    assert.ok(localized.includes('href="/assets/styles.css"'));
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
    execFileSync("npm", ["run", "build"], { cwd: marketing, stdio: "pipe" });
    assert.deepEqual(JSON.parse(readFileSync(join(output, "locales.json"))), [
      "en",
    ]);
    assert.ok(!existsSync(join(output, "es/index.html")));
    assert.ok(!existsSync(join(output, "ar/index.html")));
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
