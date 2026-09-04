"use strict";

const assert = require("assert");
const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const clients = Number(process.env.SYMPP_BURST_CLIENTS || 30);
const revision = "b".repeat(40);
const contract = "a".repeat(64);
const root = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-node-burst-"));
const codexHome = path.join(root, "codex");
const symppHome = path.join(root, "sympp");
const installedRoot = path.join(codexHome, "plugins", "cache", "symphony-plus-plus", "symphony-plus-plus-mcp", "0.1.9");
const sourceRoot = path.join(codexHome, ".tmp", "marketplaces", "symphony-plus-plus");
const sourcePluginRoot = path.join(sourceRoot, "plugins", "symphony-plus-plus-mcp");
const repoPluginRoot = path.resolve(__dirname, "../..");
const runtimeFile = path.join(symppHome, "runtime", "codex-plugin.json");
const traceDir = path.join(root, "trace");
const children = new Set();
const counts = { board: 0, readiness: 0, earlyLease: 0, attach: 0, detach: 0, initialize: 0 };
const activeLeases = new Set();
let readinessCompleted = false;
let backendStopped = false;
let readyClients = 0;
let releaseClients;
let signalAllReady;
const allReady = new Promise((resolve) => { signalAllReady = resolve; });
const released = new Promise((resolve) => { releaseClients = resolve; });

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`);
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function respond(response, status, value, headers = {}) {
  const body = typeof value === "string" ? value : JSON.stringify(value);
  response.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body), ...headers });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolve) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

async function handle(request, response) {
  if (request.url === "/sympp/board") {
    counts.board += 1;
    return respond(response, 200, "<title>Symphony++ Dashboard</title>", { "Content-Type": "text/html" });
  }
  if (request.url === "/mcp/readiness") {
    counts.readiness += 1;
    if (activeLeases.size === 0) setTimeout(() => { backendStopped = true; }, 100);
    return setTimeout(() => {
      if (backendStopped) return respond(response, 503, { status: "stopped" });
      readinessCompleted = true;
      respond(response, 200, { status: "ok", ledger: { reachable: true }, dashboard: { ready: true }, source: { mcp_contract: { fingerprint: contract } } });
    }, 250);
  }
  if (request.url === "/mcp/client-lease") {
    const payload = JSON.parse(await readBody(request));
    if (!readinessCompleted) counts.earlyLease += 1;
    if (payload.action === "attach") {
      counts.attach += 1;
      activeLeases.add(payload.client_id);
    }
    if (payload.action === "detach") {
      counts.detach += 1;
      activeLeases.delete(payload.client_id);
    }
    return respond(response, 200, { stale_after_ms: 600000 });
  }
  if (request.url === "/mcp") {
    const payload = JSON.parse(await readBody(request));
    counts.initialize += 1;
    return respond(response, 200, { jsonrpc: "2.0", id: payload.id, result: { protocolVersion: "2025-03-26", capabilities: {}, serverInfo: { name: "burst", version: "1" } } }, { "Mcp-Session-Id": crypto.randomUUID() });
  }
  respond(response, 404, "not found", { "Content-Type": "text/plain" });
}

function runClient(bridge) {
  return new Promise((resolve, reject) => {
    const environment = { ...process.env };
    for (const name of ["SYMPP_REPO_ROOT", "SYMPP_BACKEND_PORT", "SYMPP_DASHBOARD_PORT", "SYMPP_BACKEND_URL", "SYMPP_DASHBOARD_ORIGIN", "SYMPP_MCP_BRIDGE_MODE"]) delete environment[name];
    Object.assign(environment, { SYMPP_HOME: symppHome, SYMPP_RUNTIME_FILE: runtimeFile, SYMPP_LAUNCHER_TRACE_DIR: traceDir, SYMPP_STARTUP_LOCK_TIMEOUT_SEC: "30", SYMPP_MCP_HTTP_TIMEOUT_SEC: "30" });
    const child = spawn(process.execPath, [bridge], {
      env: environment,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    children.add(child);
    let stdout = "";
    let stderr = "";
    let answered = false;
    const timeout = setTimeout(() => child.kill(), 120000);
    child.stdout.on("data", (chunk) => {
      timeout.refresh();
      stdout += chunk;
      if (!answered && stdout.includes("\n")) {
        answered = true;
        readyClients += 1;
        if (readyClients === clients) signalAllReady();
        released.then(() => child.stdin.end());
      }
    });
    child.stderr.on("data", (chunk) => { timeout.refresh(); stderr += chunk; });
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timeout);
      children.delete(child);
      try {
        let trace = "";
        try { trace = fs.readFileSync(path.join(traceDir, `${child.pid}.log`), "utf8"); } catch (_) { }
        assert.equal(code, 0, stderr || trace || `bridge exited ${code}`);
        const response = JSON.parse(stdout.trim());
        assert.equal(response.result.protocolVersion, "2025-03-26");
        resolve();
      } catch (error) {
        reject(error);
      }
    });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: crypto.randomUUID(), method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "burst", version: "1" } } })}\n`);
  });
}

async function stopChildren() {
  const running = [...children];
  const stopped = running.map((child) => child.exitCode === null
    ? new Promise((resolve) => child.once("exit", resolve))
    : Promise.resolve());
  for (const child of running) child.kill();
  await Promise.all(stopped);
}

async function main() {
  const server = http.createServer((request, response) => { handle(request, response).catch((error) => respond(response, 500, error.message)); });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    fs.mkdirSync(traceDir, { recursive: true });
    for (const destination of [installedRoot, sourcePluginRoot]) {
      fs.mkdirSync(destination, { recursive: true });
      fs.cpSync(path.join(repoPluginRoot, "scripts"), path.join(destination, "scripts"), { recursive: true });
    }
    writeJson(path.join(sourceRoot, ".codex-marketplace-install.json"), { revision });
    writeJson(path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus", "mcp_contract.json"), { mcp_contract_fingerprint: contract });
    const generationKey = sha256(`${installedRoot.toLowerCase()}\n${revision}\n${contract}`);
    const validationCache = path.join(symppHome, "runtime", "launcher-validation", `${sha256(installedRoot.toLowerCase()).slice(0, 12)}.json`);
    writeJson(validationCache, { schema_version: 1, plugin_root: installedRoot, source_root: sourceRoot, generation_key: generationKey, revision, contract_fingerprint: contract });
    writeJson(runtimeFile, {
      plugin_root: installedRoot,
      runtime_key: `contract=${contract};backend=${origin};dashboard=${origin}`,
      runtime_mode: "external",
      backend: { status: "external_loopback", url: origin, managed: false, pid: null, expected_contract_fingerprint: contract, contract_fingerprint: contract, source_revision: revision },
      frontend: { status: "external_loopback", origin, managed: false, pid: null },
    });

    const started = Date.now();
    const runs = [];
    for (let index = 0; index < clients; index += 1) {
      runs.push(runClient(path.join(installedRoot, "scripts", "start-sympp-mcp-bridge.js")));
      if (index % 25 === 24) await new Promise((resolve) => setImmediate(resolve));
    }
    // Keep the fixture responsive while the Windows bridge children retain the suite's BelowNormal priority.
    if (process.platform === "win32") os.setPriority(os.constants.priority.PRIORITY_NORMAL);
    const completed = Promise.all(runs);
    await Promise.race([allReady, completed]);
    releaseClients();
    await completed;
    assert.equal(counts.board, 0, "MCP startup must not render the dashboard");
    assert.equal(counts.earlyLease, 1, "the health leader must hold the backend while all other clients wait for shared readiness");
    assert.equal(counts.attach, clients, "every bridge must attach exactly once");
    assert.equal(counts.initialize, clients, "every client must complete a bridge initialize round trip against the fixture backend");
    const localLeases = fs.existsSync(path.join(symppHome, "runtime", "codex-plugin-leases"))
      ? fs.readdirSync(path.join(symppHome, "runtime", "codex-plugin-leases")).filter((name) => /^bridge-.*\.json$/.test(name))
      : [];
    assert.equal(localLeases.length, 0, "every local bridge lease must be removed");
    assert.ok(counts.readiness <= 5, `readiness was not coalesced: ${counts.readiness}`);
    process.stdout.write(`${JSON.stringify({ clients, elapsed_ms: Date.now() - started, ...counts })}\n`);
  } finally {
    await stopChildren();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 50 });
  }
}

main().catch((error) => {
  for (const child of children) child.kill();
  try { fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 50 }); } catch (_) { }
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
