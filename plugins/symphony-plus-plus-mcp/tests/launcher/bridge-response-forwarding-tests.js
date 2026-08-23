"use strict";

const assert = require("assert/strict");
const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");
const { backendUnavailable, replayProvablyUnsent } = require("../../scripts/start-sympp-mcp-bridge.js");

const pluginRoot = path.resolve(__dirname, "../..");
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-bridge-response-"));
const codexHome = path.join(temporaryRoot, "codex");
const symppHome = path.join(temporaryRoot, "sympp");
const installedRoot = path.join(codexHome, "plugins", "cache", "test-market", "symphony-plus-plus-mcp", "0.1.9");
const sourceRoot = path.join(codexHome, ".tmp", "marketplaces", "test-market");
const sourcePluginRoot = path.join(sourceRoot, "plugins", "symphony-plus-plus-mcp");
const revision = "b".repeat(40);
const contract = "c".repeat(64);
let server;
let bridge;
const deliveryRequests = new Map();
const deliverySessions = new Map();
const forwardSessions = [];

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

async function main() {
  assert.equal(backendUnavailable({ ok: false, status: 503 }), false);
  assert.equal(backendUnavailable({ ok: false }), true);
  assert.equal(replayProvablyUnsent({ mayHaveReachedBackend: false }), true);
  assert.equal(replayProvablyUnsent({ mayHaveReachedBackend: true }), false);
  assert.equal(replayProvablyUnsent({}), false);

  fs.mkdirSync(path.join(installedRoot, "scripts"), { recursive: true });
  fs.mkdirSync(path.join(sourcePluginRoot, "scripts"), { recursive: true });
  fs.cpSync(path.join(pluginRoot, "scripts"), path.join(installedRoot, "scripts"), { recursive: true });
  fs.cpSync(path.join(pluginRoot, "scripts"), path.join(sourcePluginRoot, "scripts"), { recursive: true });
  fs.mkdirSync(path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus"), { recursive: true });
  fs.writeFileSync(path.join(sourceRoot, ".codex-marketplace-install.json"), JSON.stringify({ revision }));
  fs.writeFileSync(path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus", "mcp_contract.json"), JSON.stringify({ mcp_contract_fingerprint: contract }));

  server = http.createServer((request, response) => {
    if (request.method === "GET" && request.url === "/sympp/board") return response.end("<title>Symphony++ Dashboard</title>");
    if (request.method === "POST" && request.url === "/mcp/client-lease") return response.end(JSON.stringify({ stale_after_ms: 300000 }));
    if (request.method !== "POST" || request.url !== "/mcp") return response.writeHead(404).end();
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      const message = JSON.parse(body);
      const key = message.params && message.params.name === "record_work_package_delivery" && message.params.arguments.idempotency_key;
      if (message.params && message.params.name === "test.forward") forwardSessions.push(request.headers["mcp-session-id"]);
      if (key) {
        const requests = deliveryRequests.get(key) || [];
        requests.push(body);
        deliveryRequests.set(key, requests);
        const sessions = deliverySessions.get(key) || [];
        sessions.push(request.headers["mcp-session-id"]);
        deliverySessions.set(key, sessions);
        if (key === "replay-success" && requests.length === 1) {
          response.writeHead(200, { "Content-Type": "application/json", "Mcp-Session-Id": "test-session" });
          return response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "Server error", data: { reason: "ledger_unavailable" } } }));
        }
        if (key === "replay-failure") {
          const reason = requests.length === 1 ? "first_transient" : "second_transient";
          response.writeHead(requests.length === 1 ? 500 : 503, { "Content-Type": "application/json", "Mcp-Session-Id": "test-session" });
          return response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "Server error", data: { reason } } }));
        }
        if (key === "session-recovery" && requests.length < 3) {
          response.writeHead(requests.length === 1 ? 404 : 500, { "Content-Type": "application/json", "Mcp-Session-Id": requests.length === 1 ? "expired-session" : "recovered-session" });
          return response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "Server error", data: { reason: "session_recovery" } } }));
        }
        if (key === "successful-recovery") {
          response.writeHead(requests.length === 1 ? 404 : 200, { "Content-Type": "application/json", "Mcp-Session-Id": requests.length === 1 ? "expired-session" : "recovered-session" });
          return response.end(JSON.stringify(requests.length === 1 ? { jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "Server error" } } : { jsonrpc: "2.0", id: message.id, result: { content: [{ type: "text", text: "forwarded" }] } }));
        }
      }
      const payload = message.method === "initialize"
        ? { jsonrpc: "2.0", id: message.id, result: { protocolVersion: "2025-03-26", capabilities: {}, serverInfo: { name: "stub", version: "1" } } }
        : { jsonrpc: "2.0", id: message.id, result: { content: [{ type: "text", text: "forwarded" }] } };
      response.writeHead(200, { "Content-Type": "application/json", "Mcp-Session-Id": "test-session" });
      response.end(JSON.stringify(payload));
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });

  const backend = `http://127.0.0.1:${server.address().port}`;
  const runtimeKey = `contract=${contract};backend=${backend};dashboard=${backend}`;
  const runtimeFile = path.join(symppHome, "runtime", "codex-plugin.json");
  const generationKey = sha256(`${installedRoot.toLowerCase()}\n${revision}\n${contract}`);
  const validationDir = path.join(symppHome, "runtime", "launcher-validation");
  fs.mkdirSync(validationDir, { recursive: true });
  fs.writeFileSync(path.join(validationDir, `${sha256(installedRoot.toLowerCase()).slice(0, 12)}.json`), JSON.stringify({
    schema_version: 1, plugin_root: installedRoot, source_root: sourceRoot, revision,
    contract_fingerprint: contract, generation_key: generationKey,
  }));
  fs.writeFileSync(runtimeFile, JSON.stringify({
    plugin_root: installedRoot, runtime_key: runtimeKey, runtime_mode: "artifact",
    backend: { status: "external_loopback", url: backend, managed: false, pid: null, expected_contract_fingerprint: contract, contract_fingerprint: contract },
    frontend: { status: "artifact_static", origin: backend, managed: false, pid: null },
  }));
  fs.writeFileSync(path.join(symppHome, "runtime", "codex-plugin-health.json"), JSON.stringify({
    runtime_key: runtimeKey, backend_pid: 0, contract, validated_at_ms: Date.now(),
  }));

  const environment = { ...process.env, SYMPP_HOME: symppHome, SYMPP_RUNTIME_FILE: runtimeFile, SYMPP_MCP_BRIDGE_MODE: "http" };
  for (const name of ["SYMPP_REPO_ROOT", "SYMPP_BACKEND_PORT", "SYMPP_DASHBOARD_PORT", "SYMPP_BACKEND_URL", "SYMPP_DASHBOARD_ORIGIN"]) delete environment[name];
  bridge = spawn(process.execPath, [path.join(installedRoot, "scripts", "start-sympp-mcp-bridge.js")], {
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  bridge.stderr.on("data", (chunk) => { stderr += chunk; });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`Bridge did not attach. ${stderr}`)), 5000);
    bridge.stderr.on("data", () => {
      if (!stderr.includes("MCP bridge attached")) return;
      clearTimeout(timeout);
      resolve();
    });
    bridge.once("exit", (code) => reject(new Error(`Bridge exited ${code}. ${stderr}`)));
  });

  let responsePromise = readResponse(1);
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "test", version: "1" } } })}\n`);
  await responsePromise;
  responsePromise = readResponse(2);
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "test.forward", arguments: {} } })}\n`);
  const response = await responsePromise;
  assert.equal(response.result.content[0].text, "forwarded");

  responsePromise = readResponse(3);
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "record_work_package_delivery", arguments: { idempotency_key: "replay-success" } } })}\n`);
  assert.equal((await responsePromise).result.content[0].text, "forwarded");
  assert.equal(deliveryRequests.get("replay-success").length, 2);
  assert.equal(new Set(deliveryRequests.get("replay-success")).size, 1);

  responsePromise = readResponse(4);
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "record_work_package_delivery", arguments: { idempotency_key: "replay-failure" } } })}\n`);
  assert.equal(JSON.parse((await responsePromise).error.data.detail).error.data.reason, "second_transient");
  assert.equal(deliveryRequests.get("replay-failure").length, 2);

  responsePromise = readResponse(5);
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "record_work_package_delivery", arguments: { idempotency_key: "session-recovery" } } })}\n`);
  assert.equal((await responsePromise).result.content[0].text, "forwarded");
  assert.deepEqual(deliverySessions.get("session-recovery"), ["test-session", "test-session", "recovered-session"]);

  responsePromise = readResponse(6);
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "record_work_package_delivery", arguments: { idempotency_key: "successful-recovery" } } })}\n`);
  assert.equal((await responsePromise).result.content[0].text, "forwarded");
  responsePromise = readResponse(7);
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "test.forward", arguments: {} } })}\n`);
  await responsePromise;
  assert.equal(forwardSessions.at(-1), "recovered-session");
}

function readResponse(id) {
  return new Promise((resolve, reject) => {
    let buffer = "";
    const timeout = setTimeout(() => {
      bridge.stdout.off("data", onData);
      reject(new Error(`JSON-RPC response ${id} did not reach stdout within two seconds`));
    }, 2000);
    function onData(chunk) {
      buffer += chunk;
      const lines = buffer.split(/\r?\n/);
      buffer = lines.pop();
      for (const line of lines) {
        if (!line) continue;
        const message = JSON.parse(line);
        if (message.id !== id) continue;
        clearTimeout(timeout);
        bridge.stdout.off("data", onData);
        resolve(message);
        return;
      }
    }
    bridge.stdout.on("data", onData);
  });
}

main().then(() => {
  process.stdout.write("Node bridge response forwarding test passed.\n");
}).finally(async () => {
  if (bridge && bridge.exitCode === null) bridge.kill();
  if (server) {
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
  }
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}).catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
