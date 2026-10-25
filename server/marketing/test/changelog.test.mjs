import { test } from "node:test";
import assert from "node:assert/strict";
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

test("the offline changelog localizes published notes, routes and metadata without changing home metadata", () => {
  const root = fileURLToPath(new URL("../../../", import.meta.url));
  const fixture = mkdtempSync(join(tmpdir(), "habibi-changelog-"));
  try {
    const marketing = join(fixture, "server/marketing");
    cpSync(join(root, "server/marketing"), marketing, {
      recursive: true,
      filter: (path) => !path.includes("node_modules"),
    });
    cpSync(join(root, "server/priv/gettext"), join(fixture, "server/priv/gettext"), {
      recursive: true,
    });
    cpSync(join(root, "server/priv/theme.json"), join(fixture, "server/priv/theme.json"));
    symlinkSync(join(root, "node_modules"), join(fixture, "node_modules"), "dir");

    for (const locale of ["es", "ar"]) {
      const directory = join(fixture, "server/priv/gettext", locale, "LC_MESSAGES");
      mkdirSync(directory, { recursive: true });
      writeFileSync(join(directory, "marketing.po"), `msgid ""
msgstr ""
"Language: ${locale}\\n"
"Content-Type: text/plain; charset=UTF-8\\n"

msgid "Changelog"
msgstr "Cambios"

msgid "Changelog — Habibi"
msgstr "Historial — Habibi"

msgid "October 25, 2026"
msgstr "25 de octubre de 2026"

msgid "Steadier releases."
msgstr "Notas <script>alert(1)</script>"

msgid "pin git-cliff to the selected stable baseline"
msgstr "Fijar git-cliff a la versión estable elegida"

#, fuzzy
msgid "Features"
msgstr "UNREVIEWED"
`);
    }

    const run = (...args) => execFileSync(process.execPath, args, {
      cwd: marketing,
      stdio: "pipe",
    });
    // Extract only in the disposable fixture; the catalogue owner updates the
    // real marketing.pot. This also validates every new literal Gettext call.
    run("gettext.mjs");
    run("gettext.mjs", "--check");
    run(join(root, "node_modules/@11ty/eleventy/cmd.cjs"));
    const output = join(fixture, "server/priv/static/marketing");
    const english = readFileSync(join(output, "changelog/index.html"), "utf8");
    const spanish = readFileSync(join(output, "es/changelog/index.html"), "utf8");
    const arabic = readFileSync(join(output, "ar/changelog/index.html"), "utf8");
    const home = readFileSync(join(output, "es/index.html"), "utf8");

    assert.match(english, /<h1>Changelog<\/h1>/);
    assert.match(english, /<main class="changelog wrap" id="main">/);
    assert.match(english, /<ol class="changelog-timeline" role="list">/);
    assert.match(english, /datetime="2026-10-25T11:47:15Z"/);
    assert.match(english, /datetime="2026-10-25T11:35:18Z"/);
    assert.ok(english.indexOf('id="release-0-1-1"') < english.indexOf('id="release-0-1-0"'));
    assert.match(english, /releases\/tag\/habibi%400\.1\.1/);
    assert.match(english, /releases\/tag\/server%400\.1\.0/);
    assert.match(english, /introduce private-by-design Habibi companion platform/);
    assert.match(english, /These are not mobile app releases/);
    assert.doesNotMatch(english, /<script\b|<iframe\b|<video\b|Unreleased|OAuth/i);
    assert.match(english, /rel="canonical" href="https:\/\/habibi\.fyi\/changelog\/"/);
    assert.match(spanish, /<html lang="es" dir="ltr">/);
    assert.match(arabic, /<html lang="ar" dir="rtl">/);
    assert.match(spanish, /<title>Historial — Habibi<\/title>/);
    assert.match(spanish, /<h1>Cambios<\/h1>/);
    assert.match(spanish, /25 de octubre de 2026/);
    assert.match(spanish, /Fijar git-cliff a la versión estable elegida/);
    assert.match(spanish, /Notas &lt;script&gt;alert\(1\)&lt;\/script&gt;/);
    assert.doesNotMatch(spanish, /<script\b|UNREVIEWED/);
    assert.match(spanish, /<h3>Features<\/h3>/);
    assert.match(spanish, /rel="canonical" href="https:\/\/habibi\.fyi\/es\/changelog\/"/);
    assert.match(spanish, /property="og:url" content="https:\/\/habibi\.fyi\/es\/changelog\/"/);
    assert.match(spanish, /hreflang="ar" href="https:\/\/habibi\.fyi\/ar\/changelog\/"/);
    assert.match(spanish, /hreflang="x-default" href="https:\/\/habibi\.fyi\/changelog\/"/);
    assert.doesNotMatch(spanish, /hreflang="es" href="https:\/\/habibi\.fyi\/es\/"/);
    assert.match(spanish, /href="\/es\/changelog\/" aria-current="page">Cambios/);
    assert.match(spanish, /href="\/es\/#about"/);
    assert.match(spanish, /href="\/assets\/theme\.css"/);
    assert.match(spanish, /href="\/assets\/styles\.css"/);
    assert.match(spanish, /href="\/assets\/changelog\.css"/);
    assert.equal(
      readFileSync(join(output, "assets/changelog.css"), "utf8"),
      readFileSync(join(marketing, "site/assets/changelog.css"), "utf8"),
    );

    assert.match(home, /href="\/es\/changelog\/">Cambios/);
    assert.match(home, /hreflang="es" href="https:\/\/habibi\.fyi\/es\/"/);
    assert.doesNotMatch(home, /href="\/assets\/changelog\.css"/);
    const sitemap = readFileSync(join(output, "sitemap.xml"), "utf8");
    for (const prefix of ["/", "/es/", "/ar/"]) {
      assert.ok(sitemap.includes(`<loc>https://habibi.fyi${prefix}changelog/</loc>`));
      assert.ok(sitemap.includes(`<loc>https://habibi.fyi${prefix}</loc>`));
    }
    const catalogue = readFileSync(join(fixture, "server/priv/gettext/marketing.pot"), "utf8");
    for (const message of ["Changelog — Habibi", "October 25, 2026", "Bug fixes", "Steadier releases."]) {
      assert.ok(catalogue.includes(`msgid "${message}"`));
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
