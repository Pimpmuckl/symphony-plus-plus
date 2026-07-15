/* global process, URL */
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const assetsDir = fileURLToPath(new URL("..", import.meta.url));

export async function cleanViteOwnedOutput({
  outputDir = path.resolve(assetsDir, "../priv/static"),
  publicDir = path.resolve(assetsDir, "public"),
} = {}) {
  const inventoryPath = path.join(outputDir, ".vite", "public-assets.json");
  const publicEntries = (await readdir(publicDir)).sort();
  let previousPublicEntries = [];

  try {
    previousPublicEntries = JSON.parse(await readFile(inventoryPath, "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  if (!Array.isArray(previousPublicEntries) || previousPublicEntries.some((entry) => !entry || typeof entry !== "string" || path.basename(entry) !== entry || entry === "." || entry === "..")) {
    throw new Error("Invalid Vite public asset inventory");
  }

  const ownedEntries = new Set([".vite", "assets", "index.html", ...previousPublicEntries, ...publicEntries]);

  await Promise.all([...ownedEntries].map((entry) => rm(path.join(outputDir, entry), { force: true, recursive: true })));
  await mkdir(path.dirname(inventoryPath), { recursive: true });
  await writeFile(inventoryPath, `${JSON.stringify(publicEntries)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await cleanViteOwnedOutput();
}
