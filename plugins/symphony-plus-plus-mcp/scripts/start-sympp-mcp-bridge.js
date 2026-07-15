"use strict";

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const path = require("path");
const readline = require("readline");
const { spawnSync } = require("child_process");

const WARM_MISS = 42;
const POWERSHELL_FALLBACK = 43;
const BOARD_PATH = "/sympp/board";
const DOTNET_EPOCH_TICKS = 621355968000000000n;
const agent = new http.Agent({ keepAlive: true });
const generationWatchers = [];
let ownedGenerationMarker = null;
let generationWatchReady = false;

function trace(event) {
  const dir = process.env.SYMPP_LAUNCHER_TRACE_DIR;
  if (!dir) return;
  try {
    fs.appendFileSync(path.join(dir, `${process.pid}.log`), `${event}\n`);
  } catch (_) {
  }
}

function diagnostic(message) {
  process.stderr.write(`${message}\n`);
}

function resolveHome() {
  if (process.env.SYMPP_HOME) return path.resolve(process.env.SYMPP_HOME);
  const home = process.env.HOME || process.env.USERPROFILE;
  return path.resolve(home || require("os").tmpdir(), ".agents", "splusplus");
}

function resolveRuntimeFile() {
  return process.env.SYMPP_RUNTIME_FILE
    ? path.resolve(process.env.SYMPP_RUNTIME_FILE)
    : path.join(resolveHome(), "runtime", "codex-plugin.json");
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (_) {
    return null;
  }
}

function listPayloadFiles(root) {
  const files = [];
  function visit(directory) {
    const entries = fs.readdirSync(directory, { withFileTypes: true });
    for (const entry of entries) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (entry.isFile()) {
        const relative = path.relative(root, full).split(path.sep).join("/");
        if (relative !== ".sympp-source-revision") files.push(relative);
      }
    }
  }
  visit(root);
  files.sort();
  return files;
}

function fileGenerationPart(file, label) {
  const stat = fs.statSync(file, { bigint: true });
  const ticks = stat.mtimeNs / 100n + DOTNET_EPOCH_TICKS;
  return `${label}|${stat.size}|${ticks}`;
}

function generationKey(pluginRoot, sourcePluginRoot, sourceRoot) {
  try {
    const parts = [];
    for (const root of [pluginRoot, sourcePluginRoot]) {
      for (const relative of listPayloadFiles(root)) {
        parts.push(fileGenerationPart(path.join(root, relative), relative));
      }
    }
    for (const file of [
      path.join(pluginRoot, ".sympp-source-revision"),
      path.join(sourceRoot, ".codex-marketplace-install.json"),
      path.join(sourceRoot, "implementation_docs_symphplusplus", "mcp", "mcp_tools_contract.json"),
    ]) {
      parts.push(fileGenerationPart(file, path.resolve(file)));
    }
    return sha256(parts.join("\n"));
  } catch (_) {
    return null;
  }
}

function processAlive(pid) {
  try { process.kill(Number(pid), 0); return true; } catch (_) { return false; }
}

function closeGenerationWatchers() {
  for (const watcher of generationWatchers.splice(0)) {
    try { watcher.close(); } catch (_) { }
  }
  if (ownedGenerationMarker) {
    const marker = readJson(ownedGenerationMarker);
    if (marker && Number(marker.validator_pid) === process.pid) {
      try { fs.unlinkSync(ownedGenerationMarker); } catch (_) { }
    }
    ownedGenerationMarker = null;
  }
  generationWatchReady = false;
}
process.on("exit", closeGenerationWatchers);

function watchGeneration(paths, markerFile) {
  if (generationWatchers.length) return generationWatchReady;
  const invalidate = () => {
    try { fs.unlinkSync(markerFile); trace("generation_watch_invalidated"); } catch (_) { }
  };
  for (const entry of paths) {
    try { generationWatchers.push(fs.watch(entry.path, { recursive: entry.recursive }, invalidate)); } catch (_) { closeGenerationWatchers(); generationWatchReady = false; return false; }
  }
  generationWatchReady = true;
  return true;
}

function liveGeneration(markerFile) {
  const marker = readJson(markerFile);
  return marker && /^[0-9a-f]{64}$/i.test(String(marker.generation_key || "")) && processAlive(marker.validator_pid) ? marker.generation_key : null;
}

function coalescedGenerationKey(pluginRoot, sourcePluginRoot, sourceRoot, markerFile) {
  let generation = liveGeneration(markerFile);
  if (generation) { trace("generation_cache_hit"); return generation; }

  const lockFile = `${markerFile}.lock`;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    let lock = null;
    try { lock = fs.openSync(lockFile, "wx"); } catch (error) { if (error.code !== "EEXIST") return null; }
    if (lock !== null) {
      try {
        generation = liveGeneration(markerFile);
        if (generation) return generation;
        const watched = watchGeneration([
          { path: pluginRoot, recursive: true },
          { path: sourcePluginRoot, recursive: true },
          { path: path.join(sourceRoot, ".codex-marketplace-install.json"), recursive: false },
          { path: path.join(sourceRoot, "implementation_docs_symphplusplus", "mcp", "mcp_tools_contract.json"), recursive: false },
        ], markerFile);
        generation = generationKey(pluginRoot, sourcePluginRoot, sourceRoot);
        if (!generation) return null;
        if (!watched) return generation;
        const temporary = `${markerFile}.${process.pid}.tmp`;
        fs.writeFileSync(temporary, `${JSON.stringify({ generation_key: generation, validator_pid: process.pid })}\n`);
        try { fs.unlinkSync(markerFile); } catch (_) { }
        fs.renameSync(temporary, markerFile);
        ownedGenerationMarker = markerFile;
        trace("generation_full_scan");
        return generation;
      } finally {
        fs.closeSync(lock);
        try { fs.unlinkSync(lockFile); } catch (_) { }
      }
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    generation = liveGeneration(markerFile);
    if (generation) { trace("generation_cache_hit"); return generation; }
  }
  return null;
}

function resolveCachedIdentity(pluginRoot) {
  const versionRoot = path.resolve(pluginRoot);
  const packageRoot = path.dirname(versionRoot);
  const marketplaceRoot = path.dirname(packageRoot);
  const cacheRoot = path.dirname(marketplaceRoot);
  const pluginsRoot = path.dirname(cacheRoot);
  if (path.basename(cacheRoot).toLowerCase() !== "cache" || path.basename(pluginsRoot).toLowerCase() !== "plugins") return null;

  const codexHome = path.dirname(pluginsRoot);
  const marketplaceName = path.basename(marketplaceRoot);
  const sourceRoot = path.resolve(codexHome, ".tmp", "marketplaces", marketplaceName);
  const sourcePluginRoot = path.join(sourceRoot, "plugins", path.basename(packageRoot));
  const cacheName = sha256(versionRoot.toLowerCase()).slice(0, 12) + ".json";
  const cacheFile = path.join(resolveHome(), "runtime", "launcher-validation", cacheName);
  const generation = coalescedGenerationKey(versionRoot, sourcePluginRoot, sourceRoot, `${cacheFile}.generation`);
  if (!generation) return null;
  const cache = readJson(cacheFile);
  if (!cache || cache.schema_version !== 1 ||
      path.resolve(String(cache.plugin_root || "")).toLowerCase() !== versionRoot.toLowerCase() ||
      path.resolve(String(cache.source_root || "")).toLowerCase() !== sourceRoot.toLowerCase() ||
      cache.generation_key !== generation ||
      !/^[0-9a-f]{40}$/i.test(String(cache.revision || "")) ||
      !/^[0-9a-f]{64}$/i.test(String(cache.contract_fingerprint || "")) ||
      !/^[0-9a-f]{64}$/i.test(String(cache.payload_identity || ""))) return null;

  trace("installed_identity_cache_hit");
  return cache;
}

function trimOrigin(value) {
  return String(value || "").replace(/\/+$/, "");
}

function loopbackOrigin(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" && ["127.0.0.1", "localhost", "::1"].includes(url.hostname.toLowerCase());
  } catch (_) {
    return false;
  }
}

function configuredPortMatches(name, origin) {
  if (!process.env[name]) return true;
  const configured = Number(process.env[name]);
  if (!Number.isInteger(configured) || configured < 0 || configured > 65535) return false;
  return configured === 0 || Number(new URL(origin).port || 80) === configured;
}

function runtimeKey(backend, dashboard, contract) {
  return `contract=${contract.toLowerCase()};backend=${trimOrigin(backend).toLowerCase()};dashboard=${dashboard ? trimOrigin(dashboard).toLowerCase() : "none"}`;
}

function resolveStateIdentity(state, pluginRoot) {
  if (!state || !state.backend || !state.frontend || !state.plugin_root) return null;
  if (path.resolve(String(state.plugin_root)).toLowerCase() !== path.resolve(pluginRoot).toLowerCase()) return null;
  const identity = resolveCachedIdentity(pluginRoot);
  if (!identity) return null;

  const contract = String(identity.contract_fingerprint).toLowerCase();
  if (String(state.backend.expected_contract_fingerprint || "").toLowerCase() !== contract ||
      String(state.backend.contract_fingerprint || "").toLowerCase() !== contract) return null;
  const backend = trimOrigin(state.backend.url);
  const dashboard = trimOrigin(state.frontend.origin);
  if (!loopbackOrigin(backend) || (dashboard && !loopbackOrigin(dashboard))) return null;
  if (!configuredPortMatches("SYMPP_BACKEND_PORT", backend) ||
      (dashboard && !configuredPortMatches("SYMPP_DASHBOARD_PORT", dashboard)) ||
      (process.env.SYMPP_BACKEND_URL && trimOrigin(process.env.SYMPP_BACKEND_URL) !== backend) ||
      (process.env.SYMPP_DASHBOARD_ORIGIN && trimOrigin(process.env.SYMPP_DASHBOARD_ORIGIN) !== dashboard)) return null;

  const artifactStatic = state.runtime_mode === "artifact" && state.backend.managed === true && state.frontend.status === "artifact_static";
  const managed = state.backend.managed === true && state.frontend.managed === true;
  const headless = state.backend.managed === true && !dashboard && /^(disabled|failed)$/.test(String(state.frontend.status));
  const external = state.backend.managed !== true && state.frontend.managed !== true && state.backend.status === "external_loopback" && state.frontend.status === "external_loopback";
  if (!artifactStatic && !managed && !headless && !external) return null;
  const key = runtimeKey(backend, dashboard, contract);
  if (String(state.runtime_key || "").toLowerCase() !== key.toLowerCase()) return null;
  return { backend, dashboard, contract, runtimeKey: key, revision: identity.revision, headless };
}

function request(urlString, method, body, headers, timeoutMs) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    if (!loopbackOrigin(url.origin)) return reject(new Error(`non-loopback URL rejected: ${url.origin}`));
    const req = http.request(url, { method, headers: headers || {}, agent }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode || 0, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`request timed out after ${timeoutMs}ms`)));
    req.on("error", reject);
    if (body !== undefined && body !== null) req.end(body);
    else req.end();
  });
}

function responseLines(response) {
  const content = response.body.trim();
  if (!content) return [];
  if (!String(response.headers["content-type"] || "").toLowerCase().includes("text/event-stream")) return [content];
  const lines = [];
  for (const event of content.split(/\r?\n\r?\n/)) {
    const data = event.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trimStart()).join("\n");
    if (data && data !== "[DONE]") lines.push(data);
  }
  return lines;
}

async function mcpPost(url, body, sessionId, protocol, timeoutMs) {
  const headers = { Accept: "application/json, text/event-stream", "Content-Type": "application/json" };
  if (sessionId) headers["Mcp-Session-Id"] = sessionId;
  if (protocol) headers["MCP-Protocol-Version"] = protocol;
  const response = await request(url, "POST", body, headers, timeoutMs);
  return { ok: response.status >= 200 && response.status < 300, status: response.status, headers: response.headers, lines: responseLines(response), error: response.body || `HTTP ${response.status}` };
}

function initializeBody() {
  return JSON.stringify({ jsonrpc: "2.0", id: "sympp-plugin-launcher-init", method: "initialize", params: { protocolVersion: "2025-03-26", clientInfo: { name: "sympp-plugin-launcher", version: "0.1.0" }, capabilities: {} } });
}

function protocolFrom(lines) {
  for (const line of lines) {
    try {
      const payload = JSON.parse(line);
      if (payload.result && payload.result.protocolVersion) return String(payload.result.protocolVersion);
    } catch (_) {
    }
  }
  return null;
}

async function backendHealth(origin) {
  try {
    const mcpUrl = `${trimOrigin(origin)}/mcp`;
    const initialized = await mcpPost(mcpUrl, initializeBody(), null, null, 2000);
    const session = initialized.headers["mcp-session-id"];
    if (!initialized.ok || !session) return null;
    const protocol = protocolFrom(initialized.lines) || "2025-03-26";
    const body = JSON.stringify({ jsonrpc: "2.0", id: "sympp-plugin-launcher-health", method: "tools/call", params: { name: "sympp.health", arguments: {} } });
    const health = await mcpPost(mcpUrl, body, session, protocol, 2000);
    if (!health.ok || !health.lines.length) return null;
    const payload = JSON.parse(health.lines[0]);
    const structured = payload.result && payload.result.structuredContent;
    if (!structured) return null;
    const contract = String((structured.source && structured.source.mcp_contract && structured.source.mcp_contract.fingerprint) || (structured.mcp_contract && structured.mcp_contract.fingerprint) || "").toLowerCase();
    return { healthy: structured.status === "ok" && structured.ledger && structured.ledger.reachable === true, contract };
  } catch (_) {
    return null;
  }
}

async function sessionHealth(mcpUrl, session, protocol, contract) {
  const body = JSON.stringify({ jsonrpc: "2.0", id: "sympp-plugin-launcher-health", method: "tools/call", params: { name: "sympp.health", arguments: {} } });
  const health = await mcpPost(mcpUrl, body, session, protocol, 10000);
  if (!health.ok || !health.lines.length) return false;
  const payload = JSON.parse(health.lines[0]);
  const structured = payload.result && payload.result.structuredContent;
  const actualContract = String((structured && structured.source && structured.source.mcp_contract && structured.source.mcp_contract.fingerprint) || (structured && structured.mcp_contract && structured.mcp_contract.fingerprint) || "").toLowerCase();
  return !!structured && structured.status === "ok" && structured.ledger && structured.ledger.reachable === true && actualContract === contract;
}

function healthCacheMatches(cache, state, identity) {
  return !!cache && cache.runtime_key === identity.runtimeKey &&
    Number(cache.backend_pid) === Number(state.backend.pid) && cache.contract === identity.contract &&
    Date.now() - Number(cache.validated_at_ms) <= 2000;
}

async function ensureRuntimeHealth(mcpUrl, session, protocol, runtimeFile, state, identity) {
  const cacheFile = path.join(path.dirname(runtimeFile), "codex-plugin-health.json");
  const lockFile = `${cacheFile}.lock`;
  if (healthCacheMatches(readJson(cacheFile), state, identity)) return true;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    let lock = null;
    try { lock = fs.openSync(lockFile, "wx"); } catch (error) { if (error.code !== "EEXIST") throw error; }
    if (lock !== null) {
      try {
        if (healthCacheMatches(readJson(cacheFile), state, identity)) return true;
        if (!await sessionHealth(mcpUrl, session, protocol, identity.contract)) return false;
        const temporary = `${cacheFile}.${process.pid}.tmp`;
        fs.writeFileSync(temporary, `${JSON.stringify({ runtime_key: identity.runtimeKey, backend_pid: Number(state.backend.pid), contract: identity.contract, validated_at_ms: Date.now() })}\n`);
        try { fs.unlinkSync(cacheFile); } catch (_) { }
        fs.renameSync(temporary, cacheFile);
        return true;
      } finally {
        fs.closeSync(lock);
        try { fs.unlinkSync(lockFile); } catch (_) { }
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
    if (healthCacheMatches(readJson(cacheFile), state, identity)) return true;
  }
  return false;
}

async function dashboardHealthy(identity) {
  if (identity.headless) return true;
  try {
    const response = await request(`${identity.dashboard}${BOARD_PATH}`, "GET", null, {}, 2000);
    if (response.status < 200 || response.status >= 400 || !response.body.includes("Symphony++ Dashboard")) return false;
    if (identity.dashboard === identity.backend) return true;
    const health = await backendHealth(identity.dashboard);
    return !!health && health.healthy && health.contract === identity.contract;
  } catch (_) {
    return false;
  }
}

async function clientLease(mcpUrl, clientId, action, required) {
  try {
    const response = await request(`${trimOrigin(mcpUrl)}/client-lease`, "POST", JSON.stringify({ client_id: clientId, action }), { "Content-Type": "application/json" }, 2000);
    if (response.status < 200 || response.status >= 300) throw new Error(`HTTP ${response.status}`);
    return response.body ? JSON.parse(response.body) : {};
  } catch (error) {
    if (required) throw error;
    return null;
  }
}

function leaseDirectory(runtimeFile) {
  return path.join(path.dirname(runtimeFile), "codex-plugin-leases");
}

function createLocalLease(runtimeFile, state, identity) {
  const directory = leaseDirectory(runtimeFile);
  fs.mkdirSync(directory, { recursive: true });
  const file = path.join(directory, `bridge-${process.pid}-${crypto.randomUUID().replace(/-/g, "")}.json`);
  const temporary = `${file}.tmp`;
  const lease = {
    pid: process.pid,
    created_at: new Date().toISOString(),
    runtime_key: identity.runtimeKey,
    runtime_kind: state.backend.managed === true ? "managed" : String(state.backend.status || ""),
    source_revision: identity.revision,
    backend_url: identity.backend,
    dashboard_origin: identity.dashboard,
  };
  fs.writeFileSync(temporary, `${JSON.stringify(lease, null, 2)}\n`);
  fs.renameSync(temporary, file);
  return file;
}

function sameRuntimeLeaseExists(runtimeFile, key) {
  const directory = leaseDirectory(runtimeFile);
  let files;
  try { files = fs.readdirSync(directory).filter((name) => /^bridge-.*\.json$/.test(name)); } catch (_) { return false; }
  for (const name of files) {
    const file = path.join(directory, name);
    const lease = readJson(file);
    let active = false;
    if (lease && Number.isInteger(Number(lease.pid)) && Number(lease.pid) > 0) {
      active = processAlive(lease.pid);
    }
    if (!active) {
      try { fs.unlinkSync(file); } catch (_) { }
    } else if (String(lease.runtime_key || "").toLowerCase() === key.toLowerCase()) return true;
  }
  return false;
}

function cleanupLastDetach(runtimeFile, key) {
  if (sameRuntimeLeaseExists(runtimeFile, key)) return;
  const script = path.join(__dirname, "start-sympp-mcp.ps1");
  const args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-CleanupRuntimeKey", key];
  let result = spawnSync("pwsh.exe", args, { stdio: ["ignore", "ignore", "inherit"] });
  if (result.error && result.error.code === "ENOENT") result = spawnSync("powershell.exe", args, { stdio: ["ignore", "ignore", "inherit"] });
  if (result.error || result.status !== 0) diagnostic(`Symphony++ last-detach cleanup failed: ${result.error ? result.error.message : `exit ${result.status}`}`);
}

async function bridge(identity, state, runtimeFile) {
  const mcpUrl = `${identity.backend}/mcp`;
  const clientId = `bridge-${process.pid}-${crypto.randomUUID().replace(/-/g, "")}`;
  let attached;
  try {
    attached = await clientLease(mcpUrl, clientId, "attach", true);
  } catch (_) {
    trace("warm_miss_backend");
    process.exit(WARM_MISS);
  }
  const requestedHeartbeat = Math.max(5, Math.min(540, Number(process.env.SYMPP_MCP_CLIENT_HEARTBEAT_SEC || 300))) * 1000;
  const stale = Number(attached && attached.stale_after_ms) || 0;
  const heartbeatMs = stale > 1000 ? Math.min(requestedHeartbeat, Math.max(1000, stale - Math.min(60000, Math.max(1000, Math.floor(stale / 10))))) : requestedHeartbeat;
  const localLease = createLocalLease(runtimeFile, state, identity);
  const heartbeat = setInterval(() => { clientLease(mcpUrl, clientId, "heartbeat", false); }, heartbeatMs);
  let sessionId = null;
  let protocol = null;
  const timeoutMs = Math.max(1, Math.min(3600, Number(process.env.SYMPP_MCP_HTTP_TIMEOUT_SEC || 300))) * 1000;
  try {
    const confirmedState = readJson(runtimeFile);
    const confirmed = resolveStateIdentity(confirmedState, path.resolve(__dirname, ".."));
    if (!confirmed || confirmed.runtimeKey.toLowerCase() !== identity.runtimeKey.toLowerCase()) throw new Error("runtime changed before bridge attach");
    trace("node_bridge_selected");
    diagnostic(`Symphony++ MCP bridge attached: backend=${confirmed.backend} dashboard=${confirmed.dashboard ? confirmed.dashboard + BOARD_PATH : "disabled"} runtime=${runtimeFile}`);

    const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });
    for await (const line of input) {
      if (!line.trim()) continue;
      let parsed = null;
      try { parsed = JSON.parse(line); } catch (_) { }
      const requestProtocol = parsed && parsed.method === "initialize" && parsed.params ? String(parsed.params.protocolVersion || "") : null;
      let response;
      try {
        response = await mcpPost(mcpUrl, line, sessionId, protocol, timeoutMs);
        const nextSession = response.headers["mcp-session-id"];
        if (nextSession) sessionId = String(nextSession);
        if (!response.ok && response.status === 404 && sessionId && !requestProtocol) {
          const initialized = await mcpPost(mcpUrl, initializeBody(), null, null, timeoutMs);
          if (initialized.ok) {
            sessionId = String(initialized.headers["mcp-session-id"] || "");
            protocol = protocolFrom(initialized.lines) || "2025-03-26";
            response = await mcpPost(mcpUrl, line, sessionId, protocol, timeoutMs);
          }
        }
      } catch (error) {
        response = { ok: false, error: error.message, lines: [] };
      }
      if (!response.ok) {
        process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: parsed ? parsed.id : null, error: { code: -32000, message: "Symphony++ HTTP MCP bridge request failed.", data: { detail: response.error } } })}\n`);
        continue;
      }
      if (requestProtocol) {
        protocol = protocolFrom(response.lines) || requestProtocol;
        if (!sessionId || !await ensureRuntimeHealth(mcpUrl, sessionId, protocol, runtimeFile, state, identity)) throw new Error("backend MCP contract or ledger health did not match the prepared runtime");
      }
      for (const content of response.lines) process.stdout.write(`${content.replace(/\r?\n/g, "")}\n`);
    }
  } finally {
    clearInterval(heartbeat);
    try { fs.unlinkSync(localLease); } catch (_) { }
    await clientLease(mcpUrl, clientId, "detach", false);
    closeGenerationWatchers();
    cleanupLastDetach(runtimeFile, identity.runtimeKey);
  }
}

async function main() {
  if (Number(process.versions.node.split(".")[0]) < 18) process.exit(POWERSHELL_FALLBACK);
  if (process.argv.includes("--runtime-supported")) {
    process.exit(0);
  }
  if (process.argv.some((arg) => /^-(Help|ValidateOnly)$/i.test(arg)) || process.env.SYMPP_REPO_ROOT || String(process.env.SYMPP_MCP_BRIDGE_MODE || "http").toLowerCase() !== "http") process.exit(POWERSHELL_FALLBACK);

  const runtimeFile = resolveRuntimeFile();
  const state = readJson(runtimeFile);
  if (!state) { trace("warm_miss_state"); process.exit(WARM_MISS); }
  const pluginRoot = path.resolve(__dirname, "..");
  const identity = resolveStateIdentity(state, pluginRoot);
  if (!identity) { trace("warm_miss_state"); process.exit(WARM_MISS); }
  if (!await dashboardHealthy(identity)) { trace("warm_miss_dashboard"); process.exit(WARM_MISS); }
  await bridge(identity, state, runtimeFile);
}

main().catch((error) => {
  diagnostic(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
