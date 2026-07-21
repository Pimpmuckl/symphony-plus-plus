"use strict";

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const readline = require("readline");
const { spawn } = require("child_process");
const { performance } = require("perf_hooks");

const warmSamples = Number(process.argv[2] || 30);
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

function round(value) {
  return Math.round(value * 100) / 100;
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

function clientCommand(mode) {
  const script = path.join(pluginRoot, "scripts", "start-sympp-mcp-bridge.js");
  if (mode === "controlled") return { file: process.execPath, args: [script] };
  if (mode === "cmd_passthrough") {
    return { file: process.env.ComSpec || "cmd.exe", args: ["/d", "/s", "/c", "node.exe scripts\\start-sympp-mcp-bridge.js"] };
  }
  const server = JSON.parse(fs.readFileSync(path.join(pluginRoot, ".mcp.json"), "utf8")).symphony_plus_plus;
  return { file: server.command, args: server.args };
}

function startClient(mode = "controlled") {
  const command = clientCommand(mode);
  const child = spawn(command.file, command.args, {
    cwd: pluginRoot,
    env: bridgeEnvironment(),
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

function bridgeEnvironment(extra = {}) {
  return { ...process.env, SYMPP_HOME: symppHome, SYMPP_RUNTIME_FILE: runtimeFile, SYMPP_BACKEND_URL: "", SYMPP_DASHBOARD_ORIGIN: "", SYMPP_REPO_ROOT: "", ...extra };
}

async function verifyIntegrityRejection() {
  const bridge = path.join(pluginRoot, "scripts", "start-sympp-mcp-bridge.js");
  const cleanup = path.join(pluginRoot, "scripts", "start-sympp-mcp.ps1");
  const marker = path.join(tempRoot, "unsafe-cleanup-ran");
  const original = fs.readFileSync(cleanup);
  try {
    fs.writeFileSync(cleanup, "Set-Content -LiteralPath $env:SYMPP_INTEGRITY_MARKER -Value invoked\n");
    const child = spawn(process.execPath, [bridge], { cwd: pluginRoot, env: bridgeEnvironment({ SYMPP_INTEGRITY_MARKER: marker }), stdio: "ignore", windowsHide: true });
    const exitCode = await new Promise((resolve) => child.once("exit", resolve));
    if (exitCode === 0 || fs.existsSync(marker)) throw new Error("mismatched cleanup script was not rejected safely");
    return { rejected: true, unsafe_cleanup_skipped: true };
  } finally {
    fs.writeFileSync(cleanup, original);
  }
}

async function closeClient(client) {
  client.stdin.end();
  await new Promise((resolve) => client.once("exit", resolve));
  clients.delete(client);
}

function summary(samples) {
  const ready = samples.map((sample) => sample.ready_ms);
  return { samples: ready.length, p50_ready_ms: round(percentile(ready, 0.5)), p95_ready_ms: round(percentile(ready, 0.95)), max_ready_ms: round(percentile(ready, 1)) };
}

function medianDelta(before, after) {
  const absolute = after.p50_ready_ms - before.p50_ready_ms;
  return { p50_ms: round(absolute), p50_percentage: round((absolute / before.p50_ready_ms) * 100) };
}

async function main() {
  const server = await startBackend();
  const origin = `http://127.0.0.1:${server.address().port}`;
  prepareInstall(origin);
  try {
    const anchor = startClient();
    const cold = await anchor.ready;
    for (const mode of ["cmd_passthrough", "exact_shipped"]) {
      const client = startClient(mode);
      await client.ready;
      await closeClient(client.child);
    }
    const warm = { controlled: [], cmd_passthrough: [], exact_shipped: [] };
    for (let index = 0; index < warmSamples; index += 1) {
      const order = index % 2 === 0
        ? ["controlled", "cmd_passthrough", "exact_shipped"]
        : ["exact_shipped", "cmd_passthrough", "controlled"];
      for (const mode of order) {
        const client = startClient(mode);
        warm[mode].push(await client.ready);
        await closeClient(client.child);
      }
    }
    await closeClient(anchor.child);
    const integrity = await verifyIntegrityRejection();
    const summaries = Object.fromEntries(Object.entries(warm).map(([mode, samples]) => [mode, summary(samples)]));
    const attribution = {
      cmd_process: medianDelta(summaries.controlled, summaries.cmd_passthrough),
      shipped_batch: medianDelta(summaries.cmd_passthrough, summaries.exact_shipped),
      total_shipped_gap: medianDelta(summaries.controlled, summaries.exact_shipped),
    };
    console.log(JSON.stringify({
      commands: {
        controlled: "node scripts/start-sympp-mcp-bridge.js",
        cmd_passthrough: "cmd.exe /d /s /c node scripts/start-sympp-mcp-bridge.js",
        exact_shipped: "cmd.exe /d /s /c scripts\\start-sympp-mcp.cmd",
      },
      cold,
      warm,
      summary: {
        ...summaries,
        attribution,
      },
      integrity,
    }, null, 2));
  } finally {
    for (const client of clients) client.kill();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

main().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
