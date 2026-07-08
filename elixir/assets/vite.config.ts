import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import type { IncomingMessage, ServerResponse } from "node:http";
import path from "node:path";
import { defineConfig, type ProxyOptions } from "vite";

const apiOrigin = process.env.SYMPP_API_ORIGIN || "http://127.0.0.1:19998";
const dashboardPort = parseDashboardPort(process.env.SYMPP_DASHBOARD_PORT);
const boardPath = "/sympp/board";
const operatorProxy: Record<string, string | ProxyOptions> = {
  "/api": localOperatorProxy(),
  "/mcp": apiOrigin,
  "/sympp/board/session": localOperatorProxy(),
  "/sympp/work-packages": localOperatorProxy(),
};

function parseDashboardPort(value: string | undefined) {
  const port = Number(value);
  return Number.isInteger(port) && port > 0 ? port : 19999;
}

function redirectBoardRoot(req: IncomingMessage, res: ServerResponse, next: () => void) {
  const url = new URL(req.url || "/", "http://spp.localhost");

  if (url.pathname === "/") {
    res.statusCode = 302;
    res.setHeader("Location", `${boardPath}${url.search}`);
    res.end();
    return;
  }

  next();
}

function localOperatorProxy(): ProxyOptions {
  return {
    target: apiOrigin,
    changeOrigin: true,
    configure(proxy) {
      proxy.on("proxyReq", (proxyReq) => {
        proxyReq.setHeader("origin", apiOrigin);
      });
    },
  };
}

function manualChunks(id: string) {
  const normalized = id.replaceAll("\\", "/");
  if (normalized.includes("/node_modules/react/") || normalized.includes("/node_modules/react-dom/")) return "vendor-react";
}

export default defineConfig({
  plugins: [
    {
      name: "sympp-board-root-redirect",
      configureServer(server) {
        server.middlewares.use(redirectBoardRoot);
      },
      configurePreviewServer(server) {
        server.middlewares.use(redirectBoardRoot);
      },
    },
    tailwindcss(),
    react(),
  ],
  server: {
    host: "127.0.0.1",
    port: dashboardPort,
    strictPort: true,
    allowedHosts: ["spp.localhost"],
    proxy: operatorProxy,
  },
  preview: {
    host: "127.0.0.1",
    port: dashboardPort,
    strictPort: true,
    allowedHosts: ["spp.localhost"],
    proxy: operatorProxy,
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  build: {
    outDir: "../priv/static",
    emptyOutDir: false,
    manifest: true,
    rollupOptions: {
      output: {
        entryFileNames: "assets/[name]-[hash].js",
        chunkFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
        manualChunks,
      },
    },
  },
});
