import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { cleanViteOwnedOutput } from "./clean-vite-output.mjs";

const tempRoots = [];

afterEach(async () => {
  await Promise.all(tempRoots.splice(0).map((root) => rm(root, { force: true, recursive: true })));
});

describe("Vite output cleanup", () => {
  it("makes clean and stale-seeded output identical without deleting unrelated static files", async () => {
    const outputs = await Promise.all([seedOutput("clean"), seedOutput("stale")]);

    await Promise.all(outputs.map(cleanViteOwnedOutput));

    for (const { outputDir } of outputs) {
      expect((await readdir(outputDir)).sort()).toEqual([".vite", "phoenix-sentinel.txt"]);
      expect(await readdir(path.join(outputDir, ".vite"))).toEqual(["public-assets.json"]);
      expect(await readFile(path.join(outputDir, ".vite", "public-assets.json"), "utf8")).toBe('["splusplus-logo.png"]\n');
    }
  });
});

async function seedOutput(seed) {
  const root = await mkdtemp(path.join(os.tmpdir(), `sympp-vite-${seed}-`));
  const outputDir = path.join(root, "priv", "static");
  const publicDir = path.join(root, "assets", "public");
  tempRoots.push(root);

  await mkdir(path.join(outputDir, "assets"), { recursive: true });
  await mkdir(path.join(outputDir, ".vite"), { recursive: true });
  await mkdir(publicDir, { recursive: true });
  await writeFile(path.join(outputDir, "phoenix-sentinel.txt"), "keep");
  await writeFile(path.join(outputDir, "index.html"), "generated");
  await writeFile(path.join(outputDir, ".vite", "manifest.json"), "{}");
  await writeFile(path.join(outputDir, "assets", "index-current.js"), "current");
  await writeFile(path.join(publicDir, "splusplus-logo.png"), "logo");
  await writeFile(path.join(outputDir, "splusplus-logo.png"), "copied logo");

  if (seed === "stale") {
    await writeFile(path.join(outputDir, ".vite", "public-assets.json"), '["retired-logo.png","splusplus-logo.png"]');
    await writeFile(path.join(outputDir, "retired-logo.png"), "stale");
    await writeFile(path.join(outputDir, "assets", "index-obsolete-entry.js"), "stale");
    await writeFile(path.join(outputDir, "assets", "obsolete-chunk.js"), "stale");
    await writeFile(path.join(outputDir, "assets", "obsolete.css"), "stale");
    await writeFile(path.join(outputDir, "assets", "obsolete.woff2"), "stale");
  }

  return { outputDir, publicDir };
}
