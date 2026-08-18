"use strict";

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const net = require("net");
const path = require("path");
const readline = require("readline");
const { spawn, spawnSync } = require("child_process");

const WARM_MISS = 42;
const POWERSHELL_FALLBACK = 43;
const COLD_TIMEOUT = 44;
const GENERATION_SETTLE_MS = 100;
const HEALTH_CACHE_TTL_MS = 10000;
const EXTERNAL_HEALTH_CACHE_TTL_MS = 2000;
const HEALTH_PROBE_TIMEOUT_MS = 10000;
const HEALTH_COALESCE_TIMEOUT_MS = 30000;
const CLEANUP_SOURCE_CHANGED = Symbol("cleanup_source_changed");
const synchronousWait = new Int32Array(new SharedArrayBuffer(4));
const agent = new http.Agent({ keepAlive: true });
const generationWatchers = [];
let generationWatchReady = false;
let generationWatchVersion = 0;
let generationWatchStartedAtMs = 0;
let livenessServer = null;
let livenessPipe = null;
let livenessToken = null;
let preparationChild = null;

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

function generationKey(pluginRoot, sourcePluginRoot, sourceRoot) {
  try {
    if (!fs.statSync(pluginRoot).isDirectory() || !fs.statSync(sourcePluginRoot).isDirectory()) return null;
    const install = readJson(path.join(sourceRoot, ".codex-marketplace-install.json"));
    const contract = readJson(path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus", "mcp_contract.json"));
    const revision = String(install && (install.revision || install.source_revision || install.sourceRevision) || "").toLowerCase();
    const fingerprint = String(contract && contract.mcp_contract_fingerprint || "").toLowerCase();
    if (!/^[0-9a-f]{40}$/.test(revision) || !/^[0-9a-f]{64}$/.test(fingerprint)) return null;
    return sha256(`${path.resolve(pluginRoot).toLowerCase()}\n${revision}\n${fingerprint}`);
  } catch (_) {
    return null;
  }
}

function processAlive(pid) {
  try { process.kill(Number(pid), 0); return true; } catch (_) { return false; }
}

function ensureLivenessProbe() {
  if (livenessServer) return Promise.resolve();
  livenessPipe = `\\\\.\\pipe\\sympp-mcp-${process.pid}-${crypto.randomUUID().replace(/-/g, "")}`;
  livenessToken = crypto.randomBytes(32).toString("hex");
  return new Promise((resolve, reject) => {
    const server = net.createServer((socket) => socket.end(livenessToken));
    const failed = (error) => { try { server.close(); } catch (_) { } reject(error); };
    server.once("error", failed);
    server.listen(livenessPipe, () => {
      server.removeListener("error", failed);
      livenessServer = server;
      resolve();
    });
  });
}

function livenessMatches(pid, pipe, token) {
  if (!pipe || !token || !processAlive(pid)) return false;
  if (Number(pid) === process.pid) return pipe === livenessPipe && token === livenessToken;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    try { return fs.readFileSync(pipe, "utf8") === token; } catch (error) {
      if (["ENOENT", "ENXIO"].includes(error.code)) return false;
      if (attempt < 4) Atomics.wait(synchronousWait, 0, 0, 10);
    }
  }
  return true;
}

function closeLivenessProbe() {
  if (livenessServer) { try { livenessServer.close(); } catch (_) { } }
  livenessServer = null;
  livenessPipe = null;
  livenessToken = null;
}

function tryAcquireProcessLock(lockFile) {
  fs.mkdirSync(path.dirname(lockFile), { recursive: true });
  try {
    const fd = fs.openSync(lockFile, "wx");
    const lockId = crypto.randomUUID();
    fs.writeFileSync(fd, `${JSON.stringify({ lock_id: lockId, owner_pid: process.pid, owner_pipe: livenessPipe, owner_token: livenessToken })}\n`);
    fs.fsyncSync(fd);
    return { fd, lockId };
  } catch (error) {
    if (["EACCES", "EBUSY", "EPERM"].includes(error.code)) return null;
    if (error.code !== "EEXIST") throw error;
    const owner = readJson(lockFile);
    const ownerValid = owner && owner.lock_id && owner.owner_pipe && owner.owner_token && Number(owner.owner_pid) > 0;
    let reclaim = ownerValid && !livenessMatches(owner.owner_pid, owner.owner_pipe, owner.owner_token);
    if (!ownerValid) {
      try { reclaim = Date.now() - fs.statSync(lockFile).mtimeMs > 5000; } catch (_) { reclaim = true; }
    }
    if (reclaim) { try { fs.unlinkSync(lockFile); trace("abandoned_lock_reclaimed"); } catch (_) { } }
    return null;
  }
}

function releaseProcessLock(lockFile, lock) {
  if (!lock) return;
  try { fs.closeSync(lock.fd); } catch (_) { }
  const owner = readJson(lockFile);
  if (owner && owner.lock_id === lock.lockId) { try { fs.unlinkSync(lockFile); } catch (_) { } }
}

async function enterStartupLock(runtimeFile) {
  const lockFile = path.join(path.dirname(runtimeFile), "codex-plugin.lock");
  fs.mkdirSync(path.dirname(lockFile), { recursive: true });
  const configuredSeconds = Number(process.env.SYMPP_STARTUP_LOCK_TIMEOUT_SEC || 1800);
  const timeoutSeconds = Number.isFinite(configuredSeconds) && configuredSeconds >= 1 ? Math.min(1800, configuredSeconds) : 1800;
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    try { return fs.openSync(lockFile, "a+"); } catch (error) {
      if (!["EACCES", "EBUSY", "EPERM"].includes(error.code)) throw error;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  throw new Error(`Timed out waiting for Symphony++ launcher startup lock: ${lockFile}`);
}

function closeGenerationWatchers() {
  const count = generationWatchers.length;
  for (const watcher of generationWatchers.splice(0)) {
    try { watcher.close(); } catch (_) { }
  }
  generationWatchReady = false;
  generationWatchStartedAtMs = 0;
  if (count) trace("generation_watchers_closed");
}
process.on("exit", closeGenerationWatchers);
process.on("exit", closeLivenessProbe);

function watchGeneration(paths, markerFile) {
  if (generationWatchers.length) return generationWatchReady;
  generationWatchStartedAtMs = performance.timeOrigin + performance.now();
  const invalidate = () => {
    generationWatchVersion += 1;
    try { fs.unlinkSync(markerFile); } catch (_) { }
    trace("generation_watch_invalidated");
  };
  for (const entry of paths) {
    try { generationWatchers.push(fs.watch(entry.path, { recursive: entry.recursive }, invalidate)); } catch (_) { closeGenerationWatchers(); generationWatchReady = false; return false; }
  }
  generationWatchReady = true;
  return true;
}

function generationFromMarker(marker, watchStartedAtMs) {
  const validatedAtMs = Number(marker && marker.validated_at_ms);
  return marker && /^[0-9a-f]{64}$/i.test(String(marker.generation_key || "")) &&
    Number.isFinite(validatedAtMs) && validatedAtMs >= watchStartedAtMs ? marker.generation_key : null;
}

function liveGeneration(markerFile) {
  return generationFromMarker(readJson(markerFile), generationWatchStartedAtMs);
}

async function coalescedGenerationKey(pluginRoot, sourcePluginRoot, sourceRoot, markerFile) {
  const watched = watchGeneration([
    { path: pluginRoot, recursive: true },
    { path: sourcePluginRoot, recursive: true },
    { path: path.join(sourceRoot, ".codex-marketplace-install.json"), recursive: false },
    { path: path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus", "mcp_contract.json"), recursive: false },
  ], markerFile);
  if (!watched) return null;

  let watchVersion = generationWatchVersion;
  let generation = liveGeneration(markerFile);
  if (generation && generationWatchVersion === watchVersion) {
    trace("generation_cache_hit");
    return { key: generation, watchVersion };
  }

  const lockFile = `${markerFile}.lock`;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const lock = tryAcquireProcessLock(lockFile);
    if (lock !== null) {
      try {
        watchVersion = generationWatchVersion;
        generation = liveGeneration(markerFile);
        if (generation && generationWatchVersion === watchVersion) return { key: generation, watchVersion };
        for (let attempt = 0; attempt < 3; attempt += 1) {
          watchVersion = generationWatchVersion;
          generation = generationKey(pluginRoot, sourcePluginRoot, sourceRoot);
          if (!generation) return null;
          trace("generation_scan_complete");
          await new Promise((resolve) => setTimeout(resolve, GENERATION_SETTLE_MS));
          const confirmed = generationKey(pluginRoot, sourcePluginRoot, sourceRoot);
          if (!confirmed || confirmed !== generation || generationWatchVersion !== watchVersion) {
            trace("generation_scan_retry");
            continue;
          }
          const temporary = `${markerFile}.${process.pid}.tmp`;
          fs.writeFileSync(temporary, `${JSON.stringify({ generation_key: generation, validated_at_ms: performance.timeOrigin + performance.now() })}\n`);
          try { fs.unlinkSync(markerFile); } catch (_) { }
          fs.renameSync(temporary, markerFile);
          if (generationWatchVersion !== watchVersion || liveGeneration(markerFile) !== generation) {
            trace("generation_scan_retry");
            continue;
          }
          trace("generation_full_scan");
          return { key: generation, watchVersion };
        }
        return null;
      } finally {
        releaseProcessLock(lockFile, lock);
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
    watchVersion = generationWatchVersion;
    generation = liveGeneration(markerFile);
    if (generation && generationWatchVersion === watchVersion) {
      trace("generation_cache_hit");
      return { key: generation, watchVersion };
    }
  }
  return null;
}

async function resolveCachedIdentity(pluginRoot) {
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
  const generationMarker = `${cacheFile}.generation`;
  const generation = await coalescedGenerationKey(versionRoot, sourcePluginRoot, sourceRoot, generationMarker);
  if (!generation) return null;
  const cache = readJson(cacheFile);
  if (!cache || cache.schema_version !== 1 ||
      path.resolve(String(cache.plugin_root || "")).toLowerCase() !== versionRoot.toLowerCase() ||
      path.resolve(String(cache.source_root || "")).toLowerCase() !== sourceRoot.toLowerCase() ||
      cache.generation_key !== generation.key ||
      !/^[0-9a-f]{40}$/i.test(String(cache.revision || "")) ||
      !/^[0-9a-f]{64}$/i.test(String(cache.contract_fingerprint || ""))) return null;

  trace("installed_identity_cache_hit");
  return { ...cache, generation_marker: generationMarker, generation_watch_version: generation.watchVersion };
}

function generationStillValid(identity) {
  return identity && generationWatchReady && generationWatchVersion === identity.generationWatchVersion;
}

function generationValidForAttachment(identity) {
  if (generationStillValid(identity)) return true;
  trace("warm_miss_generation");
  if (prepareCleanupScript(identity) === CLEANUP_SOURCE_CHANGED) {
    throw new Error("Installed Symphony++ cleanup scripts changed during bridge attachment.");
  }
  return false;
}

function prepareCleanupScript(identity) {
  if (!identity || !/^[0-9a-f]{40}$/i.test(String(identity.revision || "")) ||
      !/^[0-9a-f]{64}$/i.test(String(identity.generationKey || ""))) return null;
  try {
    const names = fs.readdirSync(__dirname).filter((name) => name.toLowerCase().endsWith(".ps1")).sort();
    const directory = path.join(resolveHome(), "runtime", "launcher-cleanup", `${identity.revision}-${identity.generationKey.slice(0, 12)}`);
    const marketplaceScripts = path.join(identity.sourceRoot, "plugins", path.basename(path.dirname(identity.pluginRoot)), "scripts");
    fs.mkdirSync(directory, { recursive: true });
    const script = path.join(directory, "start-sympp-mcp.ps1");
    const markerFile = path.join(directory, "validated.json");
    const marker = readJson(markerFile);
    const fileStamps = () => Object.fromEntries(names.map((name) => [name, [
      path.join(__dirname, name), path.join(marketplaceScripts, name), path.join(directory, name),
    ].map((file) => { const stat = fs.statSync(file); return `${stat.size}:${stat.mtimeMs}`; }).join("|")]));
    let currentStamps = null;
    try { if (marker) currentStamps = fileStamps(); } catch (_) { }
    if (marker && marker.generation_key === identity.generationKey && generationStillValid(identity) &&
        JSON.stringify(marker.files) === JSON.stringify(currentStamps)) {
      trace("cleanup_scripts_cached");
      return script;
    }
    for (const name of names) {
      const source = path.join(__dirname, name);
      const destination = path.join(directory, name);
      const sourceHash = sha256(fs.readFileSync(source));
      let marketplaceHash;
      try { marketplaceHash = sha256(fs.readFileSync(path.join(marketplaceScripts, name))); } catch (_) { return CLEANUP_SOURCE_CHANGED; }
      if (sourceHash !== marketplaceHash) return CLEANUP_SOURCE_CHANGED;
      if (!fs.existsSync(destination)) {
        const temporary = `${destination}.${process.pid}.${crypto.randomUUID()}.tmp`;
        try {
          fs.copyFileSync(source, temporary, fs.constants.COPYFILE_EXCL);
          if (sha256(fs.readFileSync(temporary)) !== sourceHash) return null;
          try { fs.renameSync(temporary, destination); } catch (error) {
            if (!["EACCES", "EEXIST", "EPERM"].includes(error.code)) throw error;
          }
        } finally {
          try { fs.unlinkSync(temporary); } catch (_) { }
        }
      }
      if (sha256(fs.readFileSync(destination)) !== sourceHash) return null;
    }
    if (!fs.existsSync(script)) return null;
    const markerTemp = `${markerFile}.${process.pid}.tmp`;
    fs.writeFileSync(markerTemp, `${JSON.stringify({ generation_key: identity.generationKey, files: fileStamps() })}\n`);
    try { fs.unlinkSync(markerFile); } catch (_) { }
    fs.renameSync(markerTemp, markerFile);
    trace("cleanup_scripts_staged");
    return script;
  } catch (_) {
    return null;
  }
}

async function generationValidAtAttachment(identity) {
  if (!generationValidForAttachment(identity)) return false;
  const pluginRoot = identity.pluginRoot;
  const sourceRoot = identity.sourceRoot;
  const sourcePluginRoot = path.join(sourceRoot, "plugins", path.basename(path.dirname(pluginRoot)));
  const generation = generationKey(pluginRoot, sourcePluginRoot, sourceRoot);
  await new Promise((resolve) => setTimeout(resolve, GENERATION_SETTLE_MS));
  const confirmed = generationKey(pluginRoot, sourcePluginRoot, sourceRoot);
  const valid = generationValidForAttachment(identity) && generation === identity.generationKey && confirmed === identity.generationKey;
  trace("generation_attach_full_validation");
  return valid;
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

function resolveStateIdentity(state, pluginRoot, cachedIdentity) {
  if (!state || !state.backend || !state.frontend || !state.plugin_root) return null;
  if (path.resolve(String(state.plugin_root)).toLowerCase() !== path.resolve(pluginRoot).toLowerCase()) return null;
  const identity = cachedIdentity;
  const sourceRoot = identity && (identity.source_root || identity.sourceRoot);
  if (!sourceRoot) return null;

  const contract = String(identity.contract_fingerprint || identity.contract).toLowerCase();
  if (String(state.backend.expected_contract_fingerprint || "").toLowerCase() !== contract ||
      String(state.backend.contract_fingerprint || "").toLowerCase() !== contract) return null;
  const backend = trimOrigin(state.backend.url);
  const dashboard = trimOrigin(state.frontend.origin);
  if (!loopbackOrigin(backend) || (dashboard && !loopbackOrigin(dashboard))) return null;
  if (!configuredPortMatches("SYMPP_BACKEND_PORT", backend) ||
      (dashboard && !configuredPortMatches("SYMPP_DASHBOARD_PORT", dashboard)) ||
      (process.env.SYMPP_BACKEND_URL && trimOrigin(process.env.SYMPP_BACKEND_URL) !== backend) ||
      (process.env.SYMPP_DASHBOARD_ORIGIN && trimOrigin(process.env.SYMPP_DASHBOARD_ORIGIN) !== dashboard)) return null;

  const artifactStatic = state.runtime_mode === "artifact" && state.frontend.status === "artifact_static" &&
    (state.backend.managed === true || (state.backend.status === "external_loopback" && state.frontend.managed !== true));
  const managed = state.backend.managed === true && state.frontend.managed === true;
  const headless = state.backend.managed === true && !dashboard && /^(disabled|failed)/.test(String(state.frontend.status));
  const external = state.backend.managed !== true && state.frontend.managed !== true && state.backend.status === "external_loopback" && state.frontend.status === "external_loopback";
  if (!artifactStatic && !managed && !headless && !external) return null;
  const key = runtimeKey(backend, dashboard, contract);
  if (String(state.runtime_key || "").toLowerCase() !== key.toLowerCase()) return null;
  return {
    backend, dashboard, contract, runtimeKey: key, revision: identity.revision, headless,
    epoch: `${Number(state.backend.pid) || 0}:${String(state.publication && state.publication.backend && state.publication.backend.process_start_time_utc_ticks || "external")}`,
    pluginRoot: path.resolve(pluginRoot), sourceRoot: path.resolve(String(sourceRoot)),
    generationKey: identity.generation_key || identity.generationKey,
    generationMarker: identity.generation_marker || identity.generationMarker,
    generationWatchVersion: Number(identity.generation_watch_version ?? identity.generationWatchVersion),
  };
}

function request(urlString, method, body, headers, timeoutMs) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    if (!loopbackOrigin(url.origin)) return reject(new Error(`non-loopback URL rejected: ${url.origin}`));
    let connected = false;
    const req = http.request(url, { method, headers: headers || {}, agent }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode || 0, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
      res.once("aborted", () => { const error = new Error("response aborted before completion"); error.symppRequestMayHaveReachedBackend = true; reject(error); });
      res.once("error", (error) => { error.symppRequestMayHaveReachedBackend = true; reject(error); });
    });
    req.once("socket", (socket) => {
      if (socket.connecting) socket.once("connect", () => { connected = true; });
      else connected = true;
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`request timed out after ${timeoutMs}ms`)));
    req.on("error", (error) => {
      error.symppRequestMayHaveReachedBackend = connected;
      reject(error);
    });
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
  return { ok: response.status >= 200 && response.status < 300, status: response.status, headers: response.headers, lines: responseLines(response), error: response.body || `HTTP ${response.status}`, mayHaveReachedBackend: true };
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
    const response = await request(`${trimOrigin(origin)}/mcp/readiness`, "GET", null, { Accept: "application/json" }, HEALTH_PROBE_TIMEOUT_MS);
    if (response.status === 404) return legacyBackendHealth(mcpUrl);
    if (response.status < 200 || response.status >= 300 || !response.body) return null;
    const readiness = JSON.parse(response.body);
    const contract = String((readiness.source && readiness.source.mcp_contract && readiness.source.mcp_contract.fingerprint) || "").toLowerCase();
    const healthy = readiness.status === "ok" && readiness.ledger && readiness.ledger.reachable === true;
    return { healthy, contract, retryable: false };
  } catch (error) {
    return { healthy: false, contract: "", retryable: /timed out/i.test(String(error && error.message)) };
  }
}

async function legacyBackendHealth(mcpUrl) {
  const initialized = await mcpPost(mcpUrl, initializeBody(), null, null, HEALTH_PROBE_TIMEOUT_MS);
  const session = initialized.headers["mcp-session-id"];
  if (!initialized.ok || !session) return null;
  const protocol = protocolFrom(initialized.lines) || "2025-03-26";
  const body = JSON.stringify({ jsonrpc: "2.0", id: "sympp-plugin-launcher-health", method: "tools/call", params: { name: "sympp.health", arguments: {} } });
  const health = await mcpPost(mcpUrl, body, session, protocol, HEALTH_PROBE_TIMEOUT_MS);
  if (!health.ok || !health.lines.length) return null;
  const payload = JSON.parse(health.lines[0]);
  const structured = payload.result && payload.result.structuredContent;
  if (!structured) return null;
  const contract = String((structured.source && structured.source.mcp_contract && structured.source.mcp_contract.fingerprint) || (structured.mcp_contract && structured.mcp_contract.fingerprint) || "").toLowerCase();
  return { healthy: structured.status === "ok" && structured.ledger && structured.ledger.reachable === true, contract };
}

function healthCacheMatches(cache, state, identity) {
  const backendPid = Number(state.backend.pid);
  const ttl = backendPid > 0 ? HEALTH_CACHE_TTL_MS : EXTERNAL_HEALTH_CACHE_TTL_MS;
  return !!cache && cache.runtime_key === identity.runtimeKey &&
    Number(cache.backend_pid) === backendPid && cache.contract === identity.contract &&
    Date.now() - Number(cache.validated_at_ms) <= ttl;
}

async function ensureRuntimeHealth(runtimeFile, state, identity, clientId) {
  const cacheFile = path.join(path.dirname(runtimeFile), "codex-plugin-health.json");
  const lockFile = `${cacheFile}.lock`;
  if (healthCacheMatches(readJson(cacheFile), state, identity)) return { healthy: true, attachedResponse: null };
  const deadline = Date.now() + HEALTH_COALESCE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const lock = tryAcquireProcessLock(lockFile);
    if (lock !== null) {
      let attachedResponse = null;
      try {
        if (healthCacheMatches(readJson(cacheFile), state, identity)) return { healthy: true, attachedResponse: null };
        try {
          attachedResponse = await clientLease(`${identity.backend}/mcp`, clientId, "attach", true);
        } catch (_) {
          return { healthy: false, attachedResponse: null };
        }
        while (Date.now() < deadline) {
          const health = await backendHealth(identity.backend);
          if (health && health.contract === identity.contract && health.healthy) {
            const temporary = `${cacheFile}.${process.pid}.tmp`;
            fs.writeFileSync(temporary, `${JSON.stringify({ runtime_key: identity.runtimeKey, backend_pid: Number(state.backend.pid), contract: identity.contract, validated_at_ms: Date.now() })}\n`);
            try { fs.unlinkSync(cacheFile); } catch (_) { }
            fs.renameSync(temporary, cacheFile);
            return { healthy: true, attachedResponse };
          }
          if (!health || !health.retryable) return { healthy: false, attachedResponse };
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
        return { healthy: false, attachedResponse };
      } catch (_) {
        return { healthy: false, attachedResponse };
      } finally {
        releaseProcessLock(lockFile, lock);
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
    if (healthCacheMatches(readJson(cacheFile), state, identity)) return { healthy: true, attachedResponse: null };
  }
  return { healthy: false, attachedResponse: null };
}

async function clientLease(mcpUrl, clientId, action, required) {
  try {
    const response = await request(`${trimOrigin(mcpUrl)}/client-lease`, "POST", JSON.stringify({ client_id: clientId, action }), { "Content-Type": "application/json" }, required ? HEALTH_PROBE_TIMEOUT_MS : 2000);
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
    process_liveness_pipe: livenessPipe,
    process_liveness_token: livenessToken,
    created_at: new Date().toISOString(),
    runtime_key: identity.runtimeKey,
    runtime_kind: state.backend.managed === true ? "managed" : String(state.backend.status || ""),
    source_revision: identity.revision,
    backend_epoch: identity.epoch,
    backend_url: identity.backend,
    dashboard_origin: identity.dashboard,
  };
  fs.writeFileSync(temporary, `${JSON.stringify(lease, null, 2)}\n`);
  fs.renameSync(temporary, file);
  return file;
}

function sameRuntimeNodeLeaseExists(runtimeFile, key) {
  const directory = leaseDirectory(runtimeFile);
  let files;
  try { files = fs.readdirSync(directory).filter((name) => /^bridge-.*\.json$/.test(name)); } catch (_) { return false; }
  for (const name of files) {
    const file = path.join(directory, name);
    const lease = readJson(file);
    if (!lease || !lease.process_liveness_pipe || !lease.process_liveness_token) continue;
    const active = livenessMatches(lease.pid, lease.process_liveness_pipe, lease.process_liveness_token);
    if (!active) {
      try { fs.unlinkSync(file); } catch (_) { }
    } else if (String(lease.runtime_key || "").toLowerCase() === key.toLowerCase()) return true;
  }
  return false;
}

function cleanupLastDetach(runtimeFile, key, cleanupScript) {
  if (sameRuntimeNodeLeaseExists(runtimeFile, key)) return;
  const script = cleanupScript || path.join(__dirname, "start-sympp-mcp.ps1");
  const args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-CleanupRuntimeKey", key];
  let result = spawnSync("pwsh.exe", args, { stdio: ["ignore", "ignore", "inherit"] });
  if (result.error && result.error.code === "ENOENT") result = spawnSync("powershell.exe", args, { stdio: ["ignore", "ignore", "inherit"] });
  if (result.error || result.status !== 0) diagnostic(`Symphony++ last-detach cleanup failed: ${result.error ? result.error.message : `exit ${result.status}`}`);
  else trace("last_detach_cleanup_completed");
}

function backendUnavailable(response) {
  return !response.ok && !Number.isInteger(response.status);
}

function replayProvablyUnsent(response) {
  return response.mayHaveReachedBackend === false;
}

function indeterminateToolCall(id) {
  return {
    jsonrpc: "2.0",
    id,
    error: {
      code: -32001,
      message: "Symphony++ tool call outcome is indeterminate.",
      data: { reason: "backend_lost_after_request_started", replayed: false },
    },
  };
}

async function resolveHealthyRuntime(runtimeFile, pluginRoot, cancelled) {
  const lockFile = `${runtimeFile}.cold.lock`;
  const configuredSeconds = Number(process.env.SYMPP_COLD_START_TIMEOUT_SEC || 300);
  const deadline = Date.now() + (Number.isFinite(configuredSeconds) ? Math.max(30, Math.min(330, configuredSeconds)) : 300) * 1000;
  while (!cancelled() && Date.now() < deadline) {
    const state = readJson(runtimeFile);
    const identity = state && (!state.publication || state.publication.status === "ready")
      ? resolveStateIdentity(state, pluginRoot, await resolveCachedIdentity(pluginRoot))
      : null;
    if (identity) {
      const health = await backendHealth(identity.backend);
      if (health && health.healthy && health.contract === identity.contract) return { state, identity };
      if (state.backend.managed !== true) return null;
    }
    if (cancelled()) return null;
    const lock = tryAcquireProcessLock(lockFile);
    if (lock) {
      try {
        const confirmed = readJson(runtimeFile);
        const confirmedIdentity = confirmed && (!confirmed.publication || confirmed.publication.status === "ready")
          ? resolveStateIdentity(confirmed, pluginRoot, await resolveCachedIdentity(pluginRoot))
          : null;
        const health = confirmedIdentity && await backendHealth(confirmedIdentity.backend);
        if (!(health && health.healthy && health.contract === confirmedIdentity.contract)) {
          try { fs.unlinkSync(path.join(path.dirname(runtimeFile), "codex-plugin-health.json")); } catch (_) { }
          trace("backend_recovery_leader");
          if (!cancelled()) await prepareColdRuntime();
        }
      } finally {
        releaseProcessLock(lockFile, lock);
      }
    } else {
      await new Promise((resolve) => setTimeout(resolve, 100 + Math.floor(Math.random() * 201)));
    }
  }
  return null;
}

async function bridge(identity, state, runtimeFile) {
  const pluginRoot = path.resolve(__dirname, "..");
  const clientId = `bridge-${process.pid}-${crypto.randomUUID().replace(/-/g, "")}`;
  let current = { identity, state, mcpUrl: `${identity.backend}/mcp` };
  let localLease = null;
  let cleanupScript = null;
  let cleanupAllowed = true;
  let startupLock = null;
  let attached = false;
  let heartbeat = null;
  let recoveryPromise = null;
  let closing = false;
  let fatalRecoveryError = null;
  let input = null;
  let sessionId = null;
  let protocol = null;
  const timeoutMs = Math.max(1, Math.min(3600, Number(process.env.SYMPP_MCP_HTTP_TIMEOUT_SEC || 300))) * 1000;
  const scheduleHeartbeat = (attachedResponse) => {
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = null;
    if (closing) return;
    const requested = Math.max(5, Math.min(540, Number(process.env.SYMPP_MCP_CLIENT_HEARTBEAT_SEC || 300))) * 1000;
    const stale = Number(attachedResponse && attachedResponse.stale_after_ms) || 0;
    const interval = stale > 1000 ? Math.min(requested, Math.max(1000, stale - Math.min(60000, Math.max(1000, Math.floor(stale / 10))))) : requested;
    heartbeat = setInterval(() => {
      clientLease(current.mcpUrl, clientId, "heartbeat", false).then((response) => {
        if (!response && !closing && current.state.backend.managed === true) recover().catch((error) => {
          if (error.symppFatal) {
            fatalRecoveryError = error;
            if (input) input.close();
          } else diagnostic(`Symphony++ backend recovery failed: ${error.message}`);
        });
      });
    }, interval);
  };
  const adopt = async (runtime) => {
    const next = { ...runtime, mcpUrl: `${runtime.identity.backend}/mcp` };
    const replacementLease = next.identity.runtimeKey.toLowerCase() === current.identity.runtimeKey.toLowerCase()
      ? localLease
      : createLocalLease(runtimeFile, next.state, next.identity);
    let attachedResponse;
    let nextCleanupScript;
    let replacementAttached = false;
    try {
      attachedResponse = await clientLease(next.mcpUrl, clientId, "attach", true);
      replacementAttached = true;
      trace("replacement_lease_attached");
      nextCleanupScript = prepareCleanupScript(next.identity);
      if (nextCleanupScript === CLEANUP_SOURCE_CHANGED) {
        const error = new Error("Installed Symphony++ cleanup scripts changed during backend recovery.");
        error.symppFatal = true;
        throw error;
      }
      if (!nextCleanupScript) throw new Error("Symphony++ cleanup scripts were unavailable during backend recovery.");
      if (!await generationValidAtAttachment(next.identity)) {
        const error = new Error("Installed Symphony++ generation changed during backend recovery.");
        error.symppFatal = true;
        throw error;
      }
    } catch (error) {
      if (replacementAttached) await clientLease(next.mcpUrl, clientId, "detach", false);
      if (replacementLease !== localLease) { try { fs.unlinkSync(replacementLease); } catch (_) { } }
      throw error;
    }
    if (attached && current.mcpUrl !== next.mcpUrl) await clientLease(current.mcpUrl, clientId, "detach", false);
    if (replacementLease !== localLease) { try { fs.unlinkSync(localLease); } catch (_) { } }
    localLease = replacementLease;
    current = next;
    cleanupScript = nextCleanupScript;
    attached = true;
    sessionId = null;
    scheduleHeartbeat(attachedResponse);
    closeGenerationWatchers();
    trace("backend_recovery_ready");
  };
  const recover = () => {
    if (!recoveryPromise) {
      recoveryPromise = (async () => {
        const runtime = await resolveHealthyRuntime(runtimeFile, pluginRoot, () => closing);
        if (!runtime) throw new Error("No healthy managed Symphony++ backend was elected.");
        if (runtime.identity.epoch !== current.identity.epoch || runtime.identity.runtimeKey !== current.identity.runtimeKey || !sessionId) await adopt(runtime);
        else closeGenerationWatchers();
      })().finally(() => { recoveryPromise = null; });
    }
    return recoveryPromise;
  };
  const initializeSession = async () => {
    const initialized = await mcpPost(current.mcpUrl, initializeBody(), null, null, timeoutMs);
    if (!initialized.ok) throw new Error(initialized.error || "Symphony++ MCP session reinitialization failed.");
    sessionId = String(initialized.headers["mcp-session-id"] || "");
    protocol = protocolFrom(initialized.lines) || protocol || "2025-03-26";
  };
  try {
    try {
      startupLock = await enterStartupLock(runtimeFile);
    } catch (_) {
      trace("warm_miss_lock");
      return false;
    }
    trace("generation_attach_preflight");
    if (!generationValidForAttachment(identity)) return false;
    cleanupScript = prepareCleanupScript(identity);
    if (cleanupScript === CLEANUP_SOURCE_CHANGED) {
      cleanupAllowed = false;
      cleanupScript = null;
      throw new Error("Installed Symphony++ cleanup scripts changed during bridge attachment.");
    }
    if (!cleanupScript) {
      trace("warm_miss_cleanup");
      return false;
    }
    localLease = createLocalLease(runtimeFile, state, identity);
    fs.closeSync(startupLock);
    startupLock = null;
    trace("generation_attach_lock_released");
    const confirmedState = readJson(runtimeFile);
    const confirmed = resolveStateIdentity(confirmedState, path.resolve(__dirname, ".."), identity);
    if (!confirmed || confirmed.runtimeKey.toLowerCase() !== identity.runtimeKey.toLowerCase()) {
      trace("warm_miss_state");
      return false;
    }
    current = { identity: confirmed, state: confirmedState, mcpUrl: `${confirmed.backend}/mcp` };
    const preflight = await ensureRuntimeHealth(runtimeFile, confirmedState, confirmed, clientId);
    if (preflight.attachedResponse) {
      attached = true;
    }
    if (!preflight.healthy) {
      trace("warm_miss_health");
      return false;
    }
    if (!await generationValidAtAttachment(identity)) {
      trace("warm_miss_generation");
      return false;
    }
    let attachedResponse = preflight.attachedResponse;
    if (!attachedResponse) {
      try {
        attachedResponse = await clientLease(current.mcpUrl, clientId, "attach", true);
        attached = true;
      } catch (_) {
        trace("warm_miss_backend");
        return false;
      }
    }
    if (!generationValidForAttachment(identity)) return false;
    closeGenerationWatchers();
    trace("generation_attach_handles_released");
    scheduleHeartbeat(attachedResponse);
    trace("node_bridge_selected");
    diagnostic(`Symphony++ MCP bridge attached: backend=${confirmed.backend} dashboard=${confirmed.dashboard ? confirmed.dashboard + "/sympp/board" : "disabled"} runtime=${runtimeFile}`);

    input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });
    for await (const line of input) {
      if (!line.trim()) continue;
      let parsed = null;
      try { parsed = JSON.parse(line); } catch (_) { }
      const requestProtocol = parsed && parsed.method === "initialize" && parsed.params ? String(parsed.params.protocolVersion || "") : null;
      let response;
      try {
        if (!requestProtocol && !sessionId && protocol) await initializeSession();
        response = await mcpPost(current.mcpUrl, line, sessionId, protocol, timeoutMs);
        const nextSession = response.headers["mcp-session-id"];
        if (nextSession) sessionId = String(nextSession);
        if (!response.ok && response.status === 404 && sessionId && !requestProtocol) {
          await initializeSession();
          response = await mcpPost(current.mcpUrl, line, sessionId, protocol, timeoutMs);
        }
      } catch (error) {
        response = { ok: false, error: error.message, lines: [], mayHaveReachedBackend: error.symppRequestMayHaveReachedBackend };
      }
      if (backendUnavailable(response) && current.state.backend.managed === true) {
        const toolCall = parsed && (parsed.method === "tools/call" || Array.isArray(parsed) && parsed.some((request) => request && request.method === "tools/call"));
        const ambiguousToolCall = toolCall && response.mayHaveReachedBackend !== false;
        let recovered = false;
        try { await recover(); recovered = true; } catch (error) {
          if (error.symppFatal) throw error;
          response.error = `${response.error} Recovery failed: ${error.message}`;
        }
        if (ambiguousToolCall) {
          process.stdout.write(`${JSON.stringify(indeterminateToolCall(parsed.id))}\n`);
          continue;
        }
        if (recovered && (replayProvablyUnsent(response) || !toolCall)) {
          try {
            if (!requestProtocol) await initializeSession();
            response = await mcpPost(current.mcpUrl, line, sessionId, protocol, timeoutMs);
            const nextSession = response.headers["mcp-session-id"];
            if (nextSession) sessionId = String(nextSession);
          } catch (error) {
            response = { ok: false, error: error.message, lines: [] };
          }
        }
      }
      if (!response.ok) {
        process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: parsed ? parsed.id : null, error: { code: -32000, message: "Symphony++ HTTP MCP bridge request failed.", data: { detail: response.error } } })}\n`);
        continue;
      }
      if (requestProtocol) {
        protocol = protocolFrom(response.lines) || requestProtocol;
      }
      for (const content of response.lines) process.stdout.write(`${content.replace(/\r?\n/g, "")}\n`);
    }
    if (fatalRecoveryError) throw fatalRecoveryError;
    return true;
  } finally {
    closing = true;
    if (startupLock) { try { fs.closeSync(startupLock); } catch (_) { } }
    if (heartbeat) clearInterval(heartbeat);
    agent.destroy();
    cancelPreparation();
    if (recoveryPromise) { try { await recoveryPromise; } catch (_) { } }
    if (localLease) { try { fs.unlinkSync(localLease); } catch (_) { } }
    if (attached) await clientLease(current.mcpUrl, clientId, "detach", false);
    closeGenerationWatchers();
    if (cleanupAllowed && cleanupScript) cleanupLastDetach(runtimeFile, current.identity.runtimeKey, cleanupScript);
    closeLivenessProbe();
  }
}

function runPreparation(executable, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { env: { ...process.env, SYMPP_BACKEND_OWNER_PID: String(process.pid) }, stdio: ["ignore", "ignore", "inherit"], windowsHide: true });
    preparationChild = child;
    child.once("error", (error) => { if (preparationChild === child) preparationChild = null; reject(error); });
    child.once("exit", (code) => { if (preparationChild === child) preparationChild = null; resolve(code ?? 1); });
  });
}

function cancelPreparation() {
  const child = preparationChild;
  if (!child || !child.pid || child.exitCode !== null) return;
  if (process.platform === "win32") spawnSync("taskkill.exe", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
  else child.kill("SIGTERM");
}

async function prepareColdRuntime() {
  const configured = process.env.SYMPP_POWERSHELL;
  const candidates = configured ? [configured] : (process.platform === "win32" ? ["pwsh.exe", "powershell.exe"] : ["pwsh"]);
  const args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path.join(__dirname, "start-sympp-mcp.ps1"), "-PrepareRuntimeOnly", ...process.argv.slice(2)];
  for (const executable of candidates) {
    try {
      const code = await runPreparation(executable, args);
      if (code !== 0) throw new Error(`Symphony++ cold runtime preparation failed with exit code ${code}.`);
      return;
    } catch (error) {
      if (error && error.code === "ENOENT" && executable !== candidates[candidates.length - 1]) continue;
      throw error;
    }
  }
}

async function resolveColdRuntime(runtimeFile, pluginRoot) {
  const lockFile = `${runtimeFile}.cold.lock`;
  const configuredSeconds = Number(process.env.SYMPP_COLD_START_TIMEOUT_SEC || 300);
  const deadline = Date.now() + (Number.isFinite(configuredSeconds) ? Math.max(30, Math.min(330, configuredSeconds)) : 300) * 1000;
  while (Date.now() < deadline) {
    const state = readJson(runtimeFile);
    if (state && (!state.publication || state.publication.status === "ready")) {
      const cachedIdentity = await resolveCachedIdentity(pluginRoot);
      const identity = resolveStateIdentity(state, pluginRoot, cachedIdentity);
      if (identity) return { state, identity };
    }
    const lock = tryAcquireProcessLock(lockFile);
    if (lock) {
      try {
        const confirmed = readJson(runtimeFile);
        let confirmedIdentity = null;
        if (confirmed && (!confirmed.publication || confirmed.publication.status === "ready")) {
          confirmedIdentity = resolveStateIdentity(confirmed, pluginRoot, await resolveCachedIdentity(pluginRoot));
        }
        if (!confirmedIdentity) await prepareColdRuntime();
      } finally {
        releaseProcessLock(lockFile, lock);
      }
    } else {
      await new Promise((resolve) => setTimeout(resolve, 100 + Math.floor(Math.random() * 201)));
    }
  }
  return null;
}

async function main() {
  if (Number(process.versions.node.split(".")[0]) < 18) process.exit(POWERSHELL_FALLBACK);
  if (process.argv.includes("--runtime-supported")) {
    process.exit(0);
  }
  if (process.argv.some((arg) => /^-(Help|ValidateOnly)$/i.test(arg)) || process.env.SYMPP_REPO_ROOT || String(process.env.SYMPP_MCP_BRIDGE_MODE || "http").toLowerCase() !== "http") process.exit(POWERSHELL_FALLBACK);

  await ensureLivenessProbe();
  const runtimeFile = resolveRuntimeFile();
  const pluginRoot = path.resolve(__dirname, "..");
  const runtime = await resolveColdRuntime(runtimeFile, pluginRoot);
  if (!runtime) { trace("cold_start_timeout"); process.exit(COLD_TIMEOUT); }
  const { state, identity } = runtime;
  trace("generation_identity_resolved");
  if (!await bridge(identity, state, runtimeFile)) process.exit(WARM_MISS);
}

if (require.main === module) {
  main().catch((error) => {
    diagnostic(error && error.stack ? error.stack : String(error));
    process.exit(1);
  });
} else {
  module.exports = { backendUnavailable, generationFromMarker, generationKey, replayProvablyUnsent, resolveStateIdentity };
}
