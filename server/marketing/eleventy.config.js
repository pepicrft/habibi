import nunjucks from "nunjucks";
import { mkdirSync, writeFileSync } from "node:fs";
import { readCatalogues, translate } from "./gettext.mjs";
import {
  readTheme,
  readNativeThemes,
  themeCSS,
  themePath,
  themeVariantsPath,
  nshTheme,
} from "./theme.mjs";

export default function (eleventyConfig) {
  let catalogues = readCatalogues();
  let theme = readTheme();
  eleventyConfig.on("eleventy.before", () => {
    catalogues = readCatalogues();
    theme = readTheme();
  });
  eleventyConfig.on("eleventy.after", ({ dir }) => {
    const assets = `${dir.output}/assets`;
    mkdirSync(assets, { recursive: true });
    writeFileSync(`${assets}/theme.css`, themeCSS(theme));
    writeFileSync(`${assets}/theme.json`, JSON.stringify(theme));
    writeFileSync(`${assets}/nsh-theme.json`, JSON.stringify(nshTheme(theme)));
    writeFileSync(`${assets}/themes.json`, JSON.stringify(readNativeThemes()));
  });
  const homePath = (locale) => (locale === "en" ? "/" : `/${locale}/`);
  const environment = new nunjucks.Environment(
    new nunjucks.FileSystemLoader("site/_includes"),
    { autoescape: true },
  );
  environment.addGlobal("dgettext", function (domain, message) {
    return translate(
      catalogues,
      this.lookup("locale") ?? "en",
      domain,
      message,
    );
  });
  eleventyConfig.setLibrary("njk", environment);
  eleventyConfig.addGlobalData("theme", () => theme);
  eleventyConfig.addGlobalData("locales", () => Object.keys(catalogues).sort());
  eleventyConfig.addFilter("homePath", homePath);
  eleventyConfig.addFilter(
    "notFoundPath",
    (locale) => `${homePath(locale)}404.html`,
  );
  eleventyConfig.addFilter("languageTag", (locale) =>
    locale.replaceAll("_", "-"),
  );
  eleventyConfig.addFilter("textDirection", (locale) =>
    /^(ar|fa|he|ur)(_|$)/.test(locale) ? "rtl" : "ltr",
  );
  eleventyConfig.addWatchTarget("../priv/gettext");
  eleventyConfig.addWatchTarget(themePath.pathname);
  eleventyConfig.addWatchTarget(themeVariantsPath.pathname);
  eleventyConfig.addPassthroughCopy("site/assets");
  // Eleventy's server binds all interfaces by default, including IPv4.
  eleventyConfig.setServerOptions({
    port: 8080,
    showAllHosts: true,
    portReassignmentRetryCount: 0,
  });

  return {
    dir: {
      input: "site",
      includes: "_includes",
      output: "../priv/static/marketing",
    },
    templateFormats: ["njk"],
    htmlTemplateEngine: "njk",
  };
}
