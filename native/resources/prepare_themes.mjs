// Bundle the same public catalog Phoenix serves, without native-owned palettes.
import { writeFileSync } from "node:fs";
import { readNativeThemes } from "../../server/marketing/theme.mjs";

writeFileSync(new URL("./themes.json", import.meta.url), JSON.stringify(readNativeThemes(), null, 2) + "\n");
