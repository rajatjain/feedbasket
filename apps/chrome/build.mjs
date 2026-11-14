import { randomUUID } from "node:crypto";
import { cp, readFile, rename, rm, writeFile } from "node:fs/promises";

await rm(new URL("dist/assets", import.meta.url), { recursive: true, force: true });

for (const name of ["popup.html", "popup.css", "tokens.css", "assets"]) {
  await cp(new URL(name, import.meta.url), new URL(`dist/${name}`, import.meta.url), { recursive: true });
}

// Publish the build ID last so it only changes once the new files are ready.
const manifest = JSON.parse(await readFile(new URL("manifest.json", import.meta.url), "utf8"));
manifest.version_name = `${manifest.version} (local ${randomUUID()})`;
const pending = new URL("dist/manifest.json.tmp", import.meta.url);
await writeFile(pending, JSON.stringify(manifest, null, 2) + "\n");
await rename(pending, new URL("dist/manifest.json", import.meta.url));
