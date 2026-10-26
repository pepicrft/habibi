import { mkdir, writeFile } from "node:fs/promises";
import { nativeKitTools } from "../../client/kits-local-inference.mjs";

const directory = new URL("../core/assets/", import.meta.url);
await mkdir(directory, { recursive: true });
await writeFile(new URL("kit-tools.json", directory), `${JSON.stringify(nativeKitTools, null, 2)}\n`);
