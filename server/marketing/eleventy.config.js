import nunjucks from "nunjucks";
import { readCatalogues, translate } from "./gettext.mjs";

export default function (eleventyConfig) {
  let catalogues = readCatalogues();
  eleventyConfig.on("eleventy.before", () => {
    catalogues = readCatalogues();
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
