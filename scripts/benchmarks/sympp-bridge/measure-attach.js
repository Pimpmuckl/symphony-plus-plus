"use strict";

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const readline = require("readline");
const { spawn } = require("child_process");
const { performance } = require("perf_hooks");

const warmSamples = Number(process.argv[2] || 10);
if (!Number.isInteger(warmSamples) || warmSamples < 1) throw new Error("usage: node measure-attach.js [warm-samples]");

const repoRoot = path.resolve(__dirname, "../../..");
const sourcePlugin = path.join(repoRoot, "plugins", "symphony-plus-plus-mcp");
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-bridge-bench-"));
const codexHome = path.join(tempRoot, "codex");
const symppHome = path.join(tempRoot, "home");
const marketplace = "benchmark";
const pluginRoot = path.join(codexHome, "plugins", "cache", marketplace, "symphony-plus-plus-mcp", "0.0.0");
const sourceRoot = path.join(codexHome, ".tmp", "marketplaces", marketplace);
const sourcePluginRoot = path.join(sourceRoot, "plugins", "symphony-plus-plus-mcp");
const runtimeFile = path.join(symppHome, "runtime", "codex-plugin.json");
const revision = "a".repeat(40);
const contract = "b".repeat(64);
const clients = new Set();
let sessionNumber = 0;

function hash(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function percentile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`);
}

function response(res, status, body, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

function startBackend() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      if (req.method === "GET" && req.url === "/sympp/board") return response(res, 200, "Symphony++ Dashboard", { "content-type": "text/html" });
      if (req.method === "GET" && req.url === "/mcp/readiness") {
        return response(res, 200, { status: "ok", ledger: { reachable: true }, dashboard: { ready: true }, source: { mcp_contract: { fingerprint: contract } } });
      }
      if (req.method === "POST" && req.url === "/mcp/client-lease") return response(res, 200, { stale_after_ms: 600000 });
      if (req.method !== "POST" || req.url !== "/mcp") return response(res, 404, {});

      let raw = "";
      req.setEncoding("utf8");
      req.on("data", (chunk) => { raw += chunk; });
      req.on("end", () => {
        const request = JSON.parse(raw);
        if (request.method === "initialize") {
          sessionNumber += 1;
          return response(res, 200, { jsonrpc: "2.0", id: request.id, result: { protocolVersion: "2025-03-26", capabilities: {}, serverInfo: { name: "benchmark", version: "1" } } }, { "mcp-session-id": `session-${sessionNumber}` });
        }
        if (request.method === "notifications/initialized") return response(res, 202, "");
        if (request.method === "tools/list") return response(res, 200, { jsonrpc: "2.0", id: request.id, result: { tools: [{ name: "benchmark_tool", description: "ready", inputSchema: { type: "object" } }] } });
        return response(res, 200, { jsonrpc: "2.0", id: request.id, result: {} });
      });
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

function prepareInstall(origin) {
  fs.cpSync(sourcePlugin, pluginRoot, { recursive: true });
  fs.cpSync(sourcePlugin, sourcePluginRoot, { recursive: true });
  writeJson(path.join(sourceRoot, ".codex-marketplace-install.json"), { revision });
  writeJson(path.join(sourceRoot, "implementation_docs_symphplusplus", "mcp", "mcp_tools_contract.json"), { mcp_contract_fingerprint: contract });

  const generationKey = hash(`${path.resolve(pluginRoot).toLowerCase()}\n${revision}\n${contract}`);
  const cacheName = `${hash(path.resolve(pluginRoot).toLowerCase()).slice(0, 12)}.json`;
  writeJson(path.join(symppHome, "runtime", "launcher-validation", cacheName), {
    schema_version: 1,
    plugin_root: pluginRoot,
    source_root: sourceRoot,
    generation_key: generationKey,
    revision,
    contract_fingerprint: contract,
  });

  const runtimeKey = `contract=${contract};backend=${origin};dashboard=${origin}`;
  writeJson(runtimeFile, {
    plugin_root: pluginRoot,
    runtime_key: runtimeKey,
    runtime_mode: "source",
    backend: { url: origin, pid: process.pid, managed: false, status: "external_loopback", expected_contract_fingerprint: contract, contract_fingerprint: contract },
    frontend: { origin, managed: false, status: "external_loopback" },
  });
}

function startClient() {
  const script = path.join(pluginRoot, "scripts", "start-sympp-mcp-bridge.js");
  const child = spawn(process.execPath, [script], {
    cwd: pluginRoot,
    env: { ...process.env, SYMPP_HOME: symppHome, SYMPP_RUNTIME_FILE: runtimeFile, SYMPP_BACKEND_URL: "", SYMPP_DASHBOARD_ORIGIN: "", SYMPP_REPO_ROOT: "" },
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  clients.add(child);
  const started = performance.now();
  const errors = [];
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => errors.push(chunk));
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", clientInfo: { name: "benchmark", version: "1" }, capabilities: {} } })}\n`);

  const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  const ready = new Promise((resolve, reject) => {
    let initializeMs;
    const timeout = setTimeout(() => reject(new Error(`bridge timed out: ${errors.join("")}`)), 15000);
    child.once("exit", (code) => {
      if (initializeMs === undefined) reject(new Error(`bridge exited ${code}: ${errors.join("")}`));
    });
    lines.on("line", (line) => {
      const message = JSON.parse(line);
      if (message.id === 1) {
        initializeMs = performance.now() - started;
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })}\n`);
      } else if (message.id === 2) {
        clearTimeout(timeout);
        const readyMs = performance.now() - started;
        resolve({ initialize_ms: initializeMs, tools_ms: readyMs - initializeMs, ready_ms: readyMs, tool_count: message.result.tools.length });
      }
    });
  });
  return { child, ready };
}

async function closeClient(client) {
  client.stdin.end();
  await new Promise((resolve) => client.once("exit", resolve));
  clients.delete(client);
}

async function main() {
  const server = await startBackend();
  const origin = `http://127.0.0.1:${server.address().port}`;
  prepareInstall(origin);
  try {
    const anchor = startClient();
    const cold = await anchor.ready;
    const warm = [];
    for (let index = 0; index < warmSamples; index += 1) {
      const sample = startClient();
      warm.push(await sample.ready);
      await closeClient(sample.child);
    }
    const ready = warm.map((sample) => sample.ready_ms);
    console.log(JSON.stringify({ command: "node scripts/start-sympp-mcp-bridge.js", cold, warm, summary: { samples: warm.length, p50_ready_ms: percentile(ready, 0.5), p95_ready_ms: percentile(ready, 0.95) } }, null, 2));
    const exited = new Promise((resolve) => anchor.child.once("exit", resolve));
    anchor.child.kill();
    await exited;
    clients.delete(anchor.child);
  } finally {
    for (const client of clients) client.kill();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

main().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
