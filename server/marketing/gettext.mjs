import { readFileSync, readdirSync, mkdirSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import gettextParser from "gettext-parser";
import matter from "gray-matter";
import nunjucks from "nunjucks";

// English source and domain layout match Tuist's Gettext catalogues. Eleventy,
// rather than the running BEAM, consumes translations while building pages.
export const catalogueRoot = fileURLToPath(
  new URL("../priv/gettext/", import.meta.url),
);

export function readCatalogues() {
  const catalogues = { en: {} };
  for (const entry of readdirSync(catalogueRoot, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    if (
      !/^[a-z]{2,3}(?:_[A-Za-z0-9]{2,8})*$/.test(entry.name) ||
      entry.name === "en"
    ) {
      throw new Error(`Invalid additional locale: ${entry.name}`);
    }
    const file = join(catalogueRoot, entry.name, "LC_MESSAGES", "marketing.po");
    const parsed = gettextParser.po.parse(readFileSync(file), {
      validation: true,
    });
    if (parsed.headers.Language !== entry.name) {
      throw new Error(`Language header must match locale directory: ${file}`);
    }
    catalogues[entry.name] = parsed.translations[""] ?? {};
  }
  return catalogues;
}

export function translate(catalogues, locale, domain, message) {
  if (domain !== "marketing")
    throw new Error(`Unknown Gettext domain: ${domain}`);
  const entry = catalogues[locale]?.[message];
  return entry?.comments?.flag
    ?.split(",")
    .some((flag) => flag.trim() === "fuzzy")
    ? message
    : entry?.msgstr?.[0] || message;
}

function extract(directory, messages = {}) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      extract(path, messages);
    } else if (entry.name.endsWith(".njk")) {
      const source = readFileSync(path, "utf8");
      const { data, content } = matter(source);
      const add = (message, line) => {
        const reference = `${relative(process.cwd(), path)}:${line}`;
        const existing = messages[message];
        messages[message] = {
          msgid: message,
          msgstr: [""],
          comments: {
            reference: existing
              ? `${existing.comments.reference}\n${reference}`
              : reference,
          },
        };
      };
      for (const key of ["title", "description"]) {
        if (typeof data[key] === "string") add(data[key], 1);
      }
      const offset =
        source.slice(0, source.length - content.length).split("\n").length - 1;
      for (const call of nunjucks.parser
        .parse(content)
        .findAll(nunjucks.nodes.FunCall)) {
        if (call.name.value !== "dgettext") continue;
        const [domain, message] = call.args.children;
        if (domain?.value !== "marketing" || call.args.children.length !== 2) {
          throw new Error(
            `Use dgettext("marketing", "English source") in ${path}`,
          );
        }
        if (
          message instanceof nunjucks.nodes.Literal &&
          typeof message.value === "string"
        ) {
          add(message.value, call.lineno + offset + 1);
        } else if (
          !(
            message instanceof nunjucks.nodes.Symbol &&
            ["title", "description"].includes(message.value)
          )
        ) {
          throw new Error(
            `Gettext messages must be literal strings in ${path}`,
          );
        }
      }
    }
  }
  return messages;
}

if (
  process.argv[1] &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1])
) {
  const output = gettextParser.po.compile(
    {
      charset: "utf-8",
      headers: {
        "Project-Id-Version": "Habibi",
        "Content-Type": "text/plain; charset=UTF-8",
        "Content-Transfer-Encoding": "8bit",
      },
      translations: { "": extract("site") },
    },
    { sort: true },
  );
  const target = join(catalogueRoot, "marketing.pot");
  if (process.argv.includes("--check")) {
    if (!readFileSync(target).equals(output)) {
      throw new Error(
        "marketing.pot is out of date. Run npm run gettext:extract (without --merge).",
      );
    }
  } else {
    mkdirSync(catalogueRoot, { recursive: true });
    writeFileSync(target, output);
  }
}
