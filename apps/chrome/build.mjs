import { cp, rm } from "node:fs/promises";

await rm(new URL("dist/assets", import.meta.url), { recursive: true, force: true });

for (const name of ["manifest.json", "popup.html", "popup.css", "tokens.css", "assets"]) {
  await cp(new URL(name, import.meta.url), new URL(`dist/${name}`, import.meta.url), { recursive: true });
}
