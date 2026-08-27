import path from "node:path";
import { defineConfig } from "vite";

export default defineConfig({
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  build: {
    ssr: "src/herdr/main.ts",
    target: "node20",
    outDir: "../../plugins/symphony-plus-plus-mcp/herdr/dist",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: "sympp-herdr.mjs",
      },
    },
  },
});
