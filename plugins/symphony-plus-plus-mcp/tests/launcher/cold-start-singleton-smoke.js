"use strict";

const assert = require("assert/strict");
const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const net = require("net");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const pluginRoot = path.resolve(__dirname, "../..");
const revision = "b".repeat(40);
const contract = "c".repeat(64);
const expectedTools = ["fixture.echo", "fixture.health", "fixture.status"];

function sha256(value) { return crypto.createHash("sha256").update(value).digest("hex"); }
function writeJson(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(value)}\n`); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { return null; } }
function delay(milliseconds) { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }
function percentile(values, ratio) { return values.slice().sort((a, b) => a - b)[Math.ceil(values.length * ratio) - 1]; }
function processAlive(pid) { try { process.kill(pid, 0); return true; } catch (_) { return false; } }
async function waitFor(predicate, message, timeout = 90000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = await predicate(); if (value) return value; await delay(25); }
  throw new Error(message);
}
async function terminate(pid) {
  if (!pid) return;
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try { process.kill(pid); } catch (_) { return; }
    await delay(25);
  }
  throw new Error(`Test-owned process ${pid} did not terminate.`);
}
async function stopBackend(port, pid) {
  if (!pid) return;
  await new Promise((resolve) => {
    const request = http.get({ hostname: "127.0.0.1", port, path: "/shutdown", timeout: 1000 }, (response) => { response.resume(); response.on("end", resolve); });
    request.on("error", resolve);
    request.on("timeout", () => { request.destroy(); resolve(); });
  });
  await terminate(pid);
}
function terminateTrees(pids) {
  if (!pids.length) return;
  spawnSync("taskkill.exe", [...pids.flatMap((pid) => ["/PID", String(pid)]), "/T", "/F"], { windowsHide: true, stdio: "ignore" });
}
async function removeTree(root) {
  let lastError;
  for (let attempt = 0; attempt < 40; attempt++) {
    try { fs.rmSync(root, { recursive: true, force: true }); return; }
    catch (error) {
      if (!["EBUSY", "ENOTEMPTY", "EPERM"].includes(error.code)) throw error;
      lastError = error;
      await delay(250);
    }
  }
  throw lastError;
}
async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function portAvailable(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.listen(port, "127.0.0.1", () => server.close(() => resolve(true)));
  });
}

async function barrierClient() {
  const [, , , barrier, launcher] = process.argv;
  process.stderr.write("BARRIER_READY\n");
  await waitFor(() => fs.existsSync(barrier), "Client barrier was not released.");
  const child = spawn("cmd.exe", ["/d", "/s", "/c", launcher], { env: process.env, stdio: "inherit", windowsHide: true });
  child.on("exit", (code) => process.exit(code ?? 1));
}

function backendFixture() {
  return [
    '"use strict";',
    'const crypto=require("crypto"),fs=require("fs"),http=require("http"),path=require("path");',
    'const a=process.argv.slice(2),arg=(n)=>a[a.indexOf(n)+1],port=Number(arg("--port")),stateFile=arg("--state"),release=arg("--release"),bindRelease=arg("--bind-release"),failAfterProbe=arg("--fail-after-probe"),failRead=arg("--fail-read"),contract=arg("--contract"),revision=arg("--revision"),ledger=arg("--ledger");',
    'const tools=JSON.parse(Buffer.from(arg("--tools"),"base64").toString("utf8")),leases=new Set(),sessions=new Set();let failAfterProbeArmed=false;',
    'let previous={};try{previous=JSON.parse(fs.readFileSync(stateFile,"utf8"));}catch(_){}',
    'const state={pid:process.pid,starts:(previous.starts||0)+1,started_at:Date.now(),initialize:previous.initialize||0,tools_list:previous.tools_list||0,mutations:previous.mutations||0,attach:previous.attach||0,detach:previous.detach||0,lease_peak:previous.lease_peak||0,active_leases:0};',
    'function save(){state.active_leases=leases.size;const t=stateFile+".tmp";fs.mkdirSync(path.dirname(stateFile),{recursive:true});fs.writeFileSync(t,JSON.stringify(state));fs.renameSync(t,stateFile);}',
    'function body(r){return new Promise(q=>{const c=[];r.on("data",x=>c.push(x));r.on("end",()=>q(Buffer.concat(c).toString("utf8")));});}',
    'function send(r,s,v,h={}){const b=typeof v==="string"?v:JSON.stringify(v);r.writeHead(s,{"Content-Type":"application/json","Content-Length":Buffer.byteLength(b),...h});r.end(b);}',
    'const server=http.createServer(async(req,res)=>{',
    ' if(req.url==="/shutdown"){send(res,200,{status:"stopping"});server.close(()=>process.exit(0));return;}',
    ' if(req.url==="/mcp/readiness"){if(release&&!fs.existsSync(release))return send(res,503,{status:"starting"});return send(res,200,{status:"ok",ledger:{reachable:true},dashboard:{ready:true},source:{revision,mcp_contract:{fingerprint:contract}}});}',
    ' if(req.url==="/sympp/board")return send(res,200,"<title>Symphony++ Dashboard</title>",{"Content-Type":"text/html"});',
    ' if(req.url==="/mcp/client-lease"){const p=JSON.parse(await body(req));if(p.action==="attach")state.attach++;if(p.action==="attach"||p.action==="heartbeat")leases.add(p.client_id);if(p.action==="heartbeat"&&failAfterProbe&&fs.existsSync(failAfterProbe)){fs.unlinkSync(failAfterProbe);failAfterProbeArmed=true;}if(p.action==="detach"){state.detach++;leases.delete(p.client_id);}state.lease_peak=Math.max(state.lease_peak,leases.size);save();return send(res,200,{stale_after_ms:600000});}',
    ' if(req.url==="/mcp"){const p=JSON.parse(await body(req));let result,session=req.headers["mcp-session-id"];if(p.method==="initialize"){state.initialize++;session=crypto.randomUUID();sessions.add(session);result={protocolVersion:"2025-03-26",capabilities:{},serverInfo:{name:"cold-fixture",version:"1"}};}else if(!sessions.has(session))return send(res,404,{error:"missing session"});else if(p.method==="tools/list"){state.tools_list++;if(failRead&&fs.existsSync(failRead)){fs.unlinkSync(failRead);save();res.writeHead(200,{"Content-Type":"application/json"});res.write("{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":");return setTimeout(()=>{server.close();server.closeAllConnections?.();setTimeout(()=>process.exit(0),10);},25);}result={tools:tools.map(name=>({name,description:"fixture",inputSchema:{type:"object"}}))};}else if(p.method==="tools/call"&&p.params.name==="fixture.mutate"){state.mutations++;save();res.writeHead(200,{"Content-Type":"application/json"});res.write("{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":");return setTimeout(()=>{res.destroy();setTimeout(()=>process.exit(0),10);},25);}else return send(res,404,{error:"missing"});save();return send(res,200,{jsonrpc:"2.0",id:p.id,result},{"Mcp-Session-Id":session});}',
    ' send(res,404,{error:"not found"});',
    '});',
    'server.on("connection",socket=>{if(!failAfterProbeArmed)return;failAfterProbeArmed=false;socket.on("close",()=>{server.close();server.closeAllConnections?.();setTimeout(()=>process.exit(0),10);});});',
    'fs.mkdirSync(path.dirname(ledger),{recursive:true});fs.writeFileSync(ledger,"fixture");function listen(){if(bindRelease&&!fs.existsSync(bindRelease))return setTimeout(listen,25);server.listen(port,"127.0.0.1",save);}listen();'
  ].join("\n");
}

function createArchive(root, shell, backendPort, backendState, releaseFile, bindReleaseFile, failAfterProbeFile, failReadFile, ledgerFile) {
  const source = path.join(root, "artifact-source");
  const archive = path.join(root, "artifact.zip");
  fs.mkdirSync(path.join(source, "dashboard"), { recursive: true });
  fs.writeFileSync(path.join(source, "backend.js"), backendFixture());
  fs.writeFileSync(path.join(source, "start-runtime.cmd"), '@echo off\r\nnode "%~dp0backend.js" %*\r\n');
  fs.writeFileSync(path.join(source, "dashboard", "index.html"), "<title>Symphony++ Dashboard</title>");
  const environment = { ...process.env, FIXTURE_SOURCE: source, FIXTURE_ARCHIVE: archive };
  const zipped = spawnSync(shell, ["-NoProfile", "-NonInteractive", "-Command", "Get-ChildItem -LiteralPath $env:FIXTURE_SOURCE | Compress-Archive -DestinationPath $env:FIXTURE_ARCHIVE -Force"], { env: environment, windowsHide: true, encoding: "utf8" });
  assert.equal(zipped.status, 0, zipped.stderr);
  const dashboardHash = sha256(`index.html ${sha256(fs.readFileSync(path.join(source, "dashboard", "index.html")))}`);
  return {
    archive,
    sha: sha256(fs.readFileSync(archive)),
    dashboardHash,
    runtimeArgs: ["--port", "{port}", "--state", backendState, "--release", releaseFile, "--bind-release", bindReleaseFile, "--fail-after-probe", failAfterProbeFile, "--fail-read", failReadFile, "--contract", contract, "--revision", revision, "--ledger", ledgerFile, "--tools", Buffer.from(JSON.stringify(expectedTools)).toString("base64"), "start-runtime.ps1"],
    backendPort,
  };
}

async function createChannelServer(mode, manifestBody, archive) {
  const counts = { manifest_attempts: 0, manifest_successes: 0, archive_attempts: 0, archive_successes: 0 };
  let releaseManifest;
  let releaseArchive;
  const manifestGate = new Promise((resolve) => { releaseManifest = resolve; });
  const archiveGate = new Promise((resolve) => { releaseArchive = resolve; });
  let manifestTail = Promise.resolve();
  const server = http.createServer((request, response) => {
    if (request.url === "/manifest.json") {
      counts.manifest_attempts++;
      const attempt = counts.manifest_attempts;
      manifestTail = manifestTail.then(async () => {
        if ((mode === "manifest_death" && attempt === 1) || (mode === "powershell_fallback_recovery" && attempt === 3)) await manifestGate;
        await delay(250);
        if (response.destroyed) return;
        counts.manifest_successes++;
        response.end(manifestBody());
      });
      return;
    }
    if (request.url === "/artifact.zip") {
      counts.archive_attempts++;
      const attempt = counts.archive_attempts;
      (async () => {
        if (mode === "artifact_death" && attempt === 1) await archiveGate;
        if (response.destroyed) return;
        counts.archive_successes++;
        response.end(fs.readFileSync(archive));
      })();
      return;
    }
    response.writeHead(404).end();
  });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  return { server, counts, origin: `http://127.0.0.1:${server.address().port}`, releaseManifest, releaseArchive };
}

function tracePid(traceDir, event) {
  if (!fs.existsSync(traceDir)) return 0;
  for (const name of fs.readdirSync(traceDir)) {
    if (!name.endsWith(".log")) continue;
    if (fs.readFileSync(path.join(traceDir, name), "utf8").split(/\r?\n/).includes(event)) return Number(path.basename(name, ".log"));
  }
  return 0;
}
function traceCount(traceDir, event) {
  if (!fs.existsSync(traceDir)) return 0;
  return fs.readdirSync(traceDir).filter((n) => n.endsWith(".log")).reduce((sum, name) => sum + fs.readFileSync(path.join(traceDir, name), "utf8").split(/\r?\n/).filter((line) => line === event).length, 0);
}
function traceOrder(traceDir, before, after) {
  return fs.readdirSync(traceDir).some((name) => {
    const lines = fs.readFileSync(path.join(traceDir, name), "utf8").split(/\r?\n/);
    return lines.indexOf(before) >= 0 && lines.indexOf(before) < lines.indexOf(after);
  });
}

function startClient(barrier, launcher, environment, clients, latencies, readyTarget) {
  const child = spawn(process.execPath, [__filename, "--barrier-client", barrier, launcher], { env: environment, stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
  const client = { child, stderr: "", stdout: "", ready: false, result: null, pending: new Map() };
  clients.push(client);
  child.stderr.on("data", (chunk) => { client.stderr += chunk; });
  child.stdin.on("error", (error) => { client.stderr += `${error.code || error.message}\n`; });
  child.stdout.on("data", (chunk) => {
    client.stdout += chunk;
    const lines = client.stdout.split(/\r?\n/); client.stdout = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const response = JSON.parse(line);
      if (response.id === 1) {
        latencies.push(Date.now() - readyTarget.startedAt);
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })}\n`);
      } else if (response.id === 2) {
        if (!response.result?.tools) { client.stderr += `tools/list failed: ${line}\n`; continue; }
        assert.deepEqual(response.result.tools.map((tool) => tool.name), expectedTools);
        client.ready = true;
        readyTarget.count++;
        if (readyTarget.count === readyTarget.target) readyTarget.resolve();
      } else if (client.pending.has(response.id)) {
        client.pending.get(response.id)(response);
        client.pending.delete(response.id);
      }
    }
  });
  client.result = new Promise((resolve) => child.on("exit", (code) => resolve({ code, stderr: client.stderr })));
  return client;
}

function startJobClient(root, barrier, launcher, environment, clients, latencies, readyTarget, index) {
  const wrapper = path.join(root, `job-client-${index}.cmd`);
  const state = path.join(root, `job-client-${index}.state`);
  fs.writeFileSync(wrapper, `@echo off\r\n:wait\r\nif not exist "${barrier}" goto wait\r\ncall "${launcher}"\r\nexit /b %ERRORLEVEL%\r\n`);
  const child = spawn("pwsh.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", process.env.SYMPP_JOB_CLIENT, state, wrapper], { env: environment, stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
  const client = { child, state, stderr: "", stdout: "", ready: false, jobReady: false, rootPid: 0, result: null, pending: new Map() };
  clients.push(client);
  child.stderr.on("data", (chunk) => {
    client.stderr += chunk;
    const match = client.stderr.match(/JOB_READY:(\d+)/);
    if (match) { client.jobReady = true; client.rootPid = Number(match[1]); }
  });
  child.stdin.on("error", (error) => { client.stderr += `${error.code || error.message}\n`; });
  child.stdout.on("data", (chunk) => {
    client.stdout += chunk;
    const lines = client.stdout.split(/\r?\n/); client.stdout = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const response = JSON.parse(line);
      if (response.id === 1) {
        latencies.push(Date.now() - readyTarget.startedAt);
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })}\n`);
      } else if (response.id === 2) {
        assert.deepEqual(response.result?.tools?.map((tool) => tool.name), expectedTools);
        client.ready = true;
        readyTarget.count++;
        if (readyTarget.count === readyTarget.target) readyTarget.resolve();
      } else if (client.pending.has(response.id)) {
        client.pending.get(response.id)(response);
        client.pending.delete(response.id);
      }
    }
  });
  client.result = new Promise((resolve) => child.on("exit", (code) => resolve({ code, stderr: client.stderr })));
  return client;
}

function jobState(client) {
  try {
    const [active = "", seen = ""] = fs.readFileSync(client.state, "utf8").split(/\r?\n/);
    const parse = (value) => value.split(",").filter(Boolean).map(Number);
    return { active: parse(active), seen: parse(seen) };
  } catch (_) { return { active: [], seen: [] }; }
}
function activeLeasePids(symppHome) {
  const directory = path.join(symppHome, "runtime", "codex-plugin-leases");
  try { return fs.readdirSync(directory).map((name) => readJson(path.join(directory, name))?.pid).filter((pid) => pid && processAlive(pid)); }
  catch (_) { return []; }
}
function runtimeEpoch(runtimeFile) {
  const state = readJson(runtimeFile);
  return `${Number(state?.backend?.pid || 0)}:${String(state?.publication?.backend?.process_start_time_utc_ticks || "")}`;
}
function listenerPids(shell, port) {
  const result = spawnSync(shell, ["-NoProfile", "-NonInteractive", "-Command", "@(Get-NetTCPConnection -LocalPort $env:FIXTURE_PORT -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique) | ConvertTo-Json -Compress"], { env: { ...process.env, FIXTURE_PORT: String(port) }, encoding: "utf8", windowsHide: true });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim() ? [].concat(JSON.parse(result.stdout.trim())) : [];
}
async function closeJob(client, graceful = false) {
  if (client.child.exitCode === null) {
    if (graceful) client.child.stdin.end();
    else process.kill(client.child.pid);
  }
  await client.result;
  await waitFor(() => jobState(client).seen.every((pid) => !processAlive(pid)), `Closed Job retained a process. ${JSON.stringify(jobState(client))}`);
}
async function jobOwner(clients, pid) {
  return waitFor(() => clients.find((client) => client.child.exitCode === null && jobState(client).active.includes(pid)), `No active Job owns PID ${pid}.`);
}

async function certifyJobs({ clients, shell, runtimeFile, backendState, backendPort, traceDir, symppHome }) {
  const initial = readJson(backendState);
  assert.equal(clients.length, 32);
  assert.equal(new Set(clients.map((client) => client.rootPid)).size, 32);
  assert.equal(initial.starts, 1);
  assert.equal(traceCount(traceDir, "runtime_ready_published"), 1);
  assert.deepEqual(listenerPids(shell, backendPort), [initial.pid]);
  await waitFor(() => activeLeasePids(symppHome).length === 32, "Initial adapters did not publish 32 active leases.");
  const initialOwner = await jobOwner(clients, initial.pid);
  assert.ok(jobState(initialOwner).active.includes(initial.pid), "Initial backend was not owned by its adapter Job.");
  const sentinel = clients.find((client) => client !== initialOwner);
  const sentinelAdapter = await waitFor(() => activeLeasePids(symppHome).find((pid) => jobState(sentinel).active.includes(pid)), "Original follower adapter was not observed in its Job.");
  let requestId = 4000;

  const follower = clients.find((client) => client !== initialOwner && client !== sentinel);
  const stableEpoch = runtimeEpoch(runtimeFile);
  await closeJob(follower);
  assert.equal(runtimeEpoch(runtimeFile), stableEpoch);
  assert.deepEqual(listenerPids(shell, backendPort), [initial.pid]);
  assert.equal((await requestClient(sentinel, requestId++, "tools/list")).result?.tools?.length, expectedTools.length);

  async function rotate(trigger) {
    const before = readJson(backendState);
    const owner = await jobOwner(clients, before.pid);
    assert.ok(jobState(owner).active.includes(before.pid), "Published owner Job did not contain the backend.");
    await closeJob(owner);
    await waitFor(() => !processAlive(before.pid) && portAvailable(backendPort), "Owner Job close did not kill its backend.");
    assert.ok(processAlive(sentinelAdapter), "Original follower adapter did not survive owner Job close.");
    const response = await requestClient(trigger, requestId++, "tools/list");
    assert.equal(response.result?.tools?.length, expectedTools.length);
    const after = await waitFor(() => { const value = readJson(backendState); return value?.starts === before.starts + 1 && value; }, "Owner rotation did not create one replacement epoch.");
    assert.notEqual(after.pid, before.pid);
    assert.deepEqual(listenerPids(shell, backendPort), [after.pid]);
    await delay(250);
    assert.equal(readJson(backendState).starts, before.starts + 1);
    assert.equal((await requestClient(sentinel, requestId++, "tools/list")).result?.tools?.length, expectedTools.length);
    assert.ok(processAlive(sentinelAdapter));
    return after;
  }

  const firstTrigger = clients.find((client) => client.child.exitCode === null && client !== sentinel && client !== initialOwner);
  await rotate(firstTrigger);
  const secondOwner = await jobOwner(clients, readJson(backendState).pid);
  const secondTrigger = clients.find((client) => client.child.exitCode === null && client !== sentinel && client !== firstTrigger && client !== secondOwner);
  await rotate(secondTrigger);

  const currentOwner = await jobOwner(clients, readJson(backendState).pid);
  const beforePrune = runtimeEpoch(runtimeFile);
  for (const client of clients) if (client.child.exitCode === null && client !== sentinel && client !== currentOwner) await closeJob(client);
  assert.equal(runtimeEpoch(runtimeFile), beforePrune);
  assert.deepEqual(listenerPids(shell, backendPort), [readJson(backendState).pid]);
  assert.deepEqual(clients.filter((client) => client.child.exitCode === null), [sentinel, currentOwner]);
  await rotate(sentinel);

  const beforeBackendCrash = readJson(backendState);
  const sentinelRoot = sentinel.rootPid;
  process.kill(beforeBackendCrash.pid);
  await waitFor(() => !processAlive(beforeBackendCrash.pid), "Backend-only crash did not stop the backend.");
  assert.ok(processAlive(sentinelAdapter) && processAlive(sentinelRoot), "Backend-only crash killed the original STDIO client.");
  assert.equal((await requestClient(sentinel, requestId++, "tools/list")).result?.tools?.length, expectedTools.length);
  const afterBackendCrash = await waitFor(() => { const value = readJson(backendState); return value?.starts === beforeBackendCrash.starts + 1 && value; }, "Backend-only crash did not recover once.");
  assert.deepEqual(listenerPids(shell, backendPort), [afterBackendCrash.pid]);

  const indeterminate = await requestClient(sentinel, requestId++, "tools/call", { name: "fixture.mutate", arguments: {} });
  assert.equal(indeterminate.error?.code, -32001);
  assert.equal(indeterminate.error?.data?.replayed, false);
  const afterMutation = await waitFor(() => { const value = readJson(backendState); return value?.starts === afterBackendCrash.starts + 1 && value; }, "Ambiguous mutation did not recover one backend.");
  assert.equal(afterMutation.mutations, 1);
  assert.equal((await requestClient(sentinel, requestId++, "tools/list")).result?.tools?.length, expectedTools.length);
  assert.equal(readJson(backendState).mutations, 1);
  assert.equal(traceCount(traceDir, "runtime_ready_published"), 6);

  await closeJob(sentinel, true);
  await waitFor(() => portAvailable(backendPort), "Final Job close retained the backend listener.");
  await waitFor(() => fs.readdirSync(path.join(symppHome, "runtime", "codex-plugin-leases"), { withFileTypes: true }).filter((entry) => entry.isFile()).length === 0, "Final Job close retained an adapter lease file.");
  const seen = [...new Set(clients.flatMap((client) => jobState(client).seen))];
  assert.ok(seen.length >= clients.length * 2, "Job snapshots did not observe launcher descendants.");
  assert.ok(seen.every((pid) => !processAlive(pid)), `Final Job close retained test-owned processes: ${seen.filter(processAlive)}`);
  assert.ok(clients.every((client) => client.child.exitCode !== null));
  return { mode: "job_certification", clients: 32, initial_epochs: 1, owner_rotations: 3, backend_recoveries: 2, mutations: 1, original_stdio: true, processes_after: 0, listeners_after: 0, active_leases_after: 0 };
}

function requestClientLine(client, id, line) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { client.pending.delete(id); reject(new Error(`Client request ${id} timed out. ${client.stderr}`)); }, 90000);
    client.pending.set(id, (response) => { clearTimeout(timeout); resolve(response); });
    client.child.stdin.write(`${line}\n`);
  });
}

function requestClient(client, id, method, params = {}) {
  return requestClientLine(client, id, JSON.stringify({ jsonrpc: "2.0", id, method, params }));
}

function assertLockFree(shell, startupLock, artifactLock) {
  const environment = { ...process.env, LOCK_PATHS: `${startupLock}|${artifactLock}` };
  const result = spawnSync(shell, ["-NoProfile", "-NonInteractive", "-Command", "$env:LOCK_PATHS.Split('|') | ForEach-Object { $f=[IO.File]::Open($_,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$f.Dispose() }"], { env: environment, windowsHide: true, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
}

async function runCase(clientCount, shell, mode = "normal") {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `sympp-cold-${mode}-`));
  const codexHome = path.join(root, "codex");
  const symppHome = path.join(root, "sympp");
  const installedRoot = path.join(codexHome, "plugins", "cache", "test-market", "symphony-plus-plus-mcp", "0.1.9");
  const sourceRoot = path.join(codexHome, ".tmp", "marketplaces", "test-market");
  const sourcePluginRoot = path.join(sourceRoot, "plugins", "symphony-plus-plus-mcp");
  const runtimeFile = path.join(symppHome, "runtime", "codex-plugin.json");
  const traceDir = path.join(root, "trace");
  const backendState = path.join(root, "backend-state.json");
  const releaseFile = path.join(root, "backend-ready");
  const bindReleaseFile = path.join(root, "backend-bind-ready");
  const failAfterProbeFile = path.join(root, "fail-after-probe");
  const failReadFile = path.join(root, "fail-read");
  const ledgerFile = path.join(root, "ledger", "fixture.sqlite3");
  const barrier = path.join(root, "barrier");
  const backendPort = await freePort();
  const clients = [];
  let channel;
  let backendPid = 0;
  try {
    fs.mkdirSync(traceDir, { recursive: true });
    for (const destination of [installedRoot, sourcePluginRoot]) {
      fs.mkdirSync(destination, { recursive: true });
      fs.cpSync(path.join(pluginRoot, "scripts"), path.join(destination, "scripts"), { recursive: true });
    }
    fs.mkdirSync(path.join(installedRoot, "assets"), { recursive: true });
    fs.cpSync(path.join(pluginRoot, ".codex-plugin"), path.join(installedRoot, ".codex-plugin"), { recursive: true });
    fs.mkdirSync(path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus"), { recursive: true });
    fs.writeFileSync(path.join(sourceRoot, "elixir", "mix.exs"), "[]");
    writeJson(path.join(sourceRoot, ".codex-marketplace-install.json"), { revision });
    writeJson(path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus", "mcp_contract.json"), { mcp_contract_fingerprint: contract });
    if (mode !== "backend_death") fs.writeFileSync(releaseFile, "ready");
    if (mode !== "backend_prebind_death") fs.writeFileSync(bindReleaseFile, "ready");
    const artifact = createArchive(root, shell, backendPort, backendState, releaseFile, bindReleaseFile, failAfterProbeFile, failReadFile, ledgerFile);
    let resolvedManifest;
    channel = await createChannelServer(mode, () => JSON.stringify(resolvedManifest), artifact.archive);
    resolvedManifest = {
      schema_version: 1, source_revision: revision, plugin: { name: "symphony-plus-plus-mcp", version: "0.1.9" },
      launcher_contract: { mcp_contract_fingerprint: contract },
      artifacts: [{ platform: "windows-x86_64", source_revision: revision, mcp_contract_fingerprint: contract,
        url: `${channel.origin}/artifact.zip`, sha256: artifact.sha, entrypoint: "start-runtime.cmd", runtime_args: artifact.runtimeArgs,
        dashboard: { asset_root: "dashboard", fingerprint: artifact.dashboardHash } }],
    };
    const resolvedText = JSON.stringify(resolvedManifest);
    writeJson(path.join(installedRoot, "assets", "sympp-runtime-artifacts.json"), { schema_version: 1, channel: "test", manifest: { url: `${channel.origin}/manifest.json`, sha256: sha256(resolvedText) } });

    const environment = { ...process.env, SYMPP_HOME: symppHome, SYMPP_RUNTIME_FILE: runtimeFile, SYMPP_LOG_DIR: path.join(root, "logs"), SYMPP_LAUNCHER_TRACE_DIR: traceDir,
      SYMPP_BACKEND_PORT: String(backendPort), SYMPP_DASHBOARD_PORT: String(backendPort), SYMPP_POWERSHELL: shell,
      SYMPP_COLD_START_TIMEOUT_SEC: "90", SYMPP_BACKEND_STARTUP_TIMEOUT_SEC: "60", SYMPP_BACKEND_PORT_RELEASE_TIMEOUT_SEC: "1",
      SYMPP_ELIXIR_SETUP_TIMEOUT_SEC: "30", SYMPP_AUTOSTART_FRONTEND: "0", SYMPP_MCP_HTTP_TIMEOUT_SEC: "30", TEMP: path.join(root, "tmp"), TMP: path.join(root, "tmp") };
    if (mode === "shutdown_during_recovery") environment.SYMPP_MCP_CLIENT_HEARTBEAT_SEC = "5";
    if (mode.startsWith("powershell_fallback")) environment.SYMPP_NODE_BRIDGE = "0";
    for (const name of ["SYMPP_REPO_ROOT", "SYMPP_BACKEND_URL", "SYMPP_DASHBOARD_ORIGIN", "SYMPP_DATABASE", "SYMPP_SOURCE_FALLBACK", "SYMPP_ARTIFACT_RUNTIME"]) delete environment[name];
    fs.mkdirSync(environment.TEMP, { recursive: true });

    let readyResolve;
    const readyTarget = { count: 0, target: clientCount, startedAt: 0, resolve: () => readyResolve() };
    const allReady = new Promise((resolve) => { readyResolve = resolve; });
    const latencies = [];
    const jobCertification = mode === "job_certification";
    for (let index = 0; index < clientCount; index++) {
      if (jobCertification) startJobClient(root, barrier, path.join(installedRoot, "scripts", "start-sympp-mcp.cmd"), environment, clients, latencies, readyTarget, index);
      else startClient(barrier, path.join(installedRoot, "scripts", "start-sympp-mcp.cmd"), environment, clients, latencies, readyTarget);
    }
    await waitFor(() => jobCertification ? clients.every((client) => client.jobReady) : clients.every((client) => client.stderr.includes("BARRIER_READY")), "Clients did not reach the start barrier.");
    readyTarget.startedAt = Date.now();
    for (const client of clients) client.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "cold-herd", version: "1" } } })}\n`);
    fs.writeFileSync(barrier, "go");

    if (mode === "manifest_death") {
      const leader = await waitFor(() => channel.counts.manifest_attempts && tracePid(traceDir, "manifest_fetch_begin"), "Manifest leader was not observed.");
      await terminate(leader); await delay(250); channel.releaseManifest();
      const replacement = startClient(barrier, path.join(installedRoot, "scripts", "start-sympp-mcp.cmd"), environment, clients, latencies, readyTarget);
      replacement.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "replacement", version: "1" } } })}\n`);
    } else if (mode === "artifact_death") {
      const leader = await waitFor(() => channel.counts.archive_attempts && tracePid(traceDir, "artifact_prepare_begin"), "Artifact leader was not observed.");
      await terminate(leader); await delay(250); channel.releaseArchive();
      const replacement = startClient(barrier, path.join(installedRoot, "scripts", "start-sympp-mcp.cmd"), environment, clients, latencies, readyTarget);
      replacement.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "replacement", version: "1" } } })}\n`);
    } else if (mode === "backend_death") {
      const starting = await waitFor(() => { const state = readJson(runtimeFile); const backend = readJson(backendState); return state?.publication?.backend?.pid && backend?.pid === state.publication.backend.pid && state; }, "Bound backend was not published before readiness.");
      await terminate(Number(starting.publication.leader_pid)); fs.writeFileSync(releaseFile, "ready");
      const replacement = startClient(barrier, path.join(installedRoot, "scripts", "start-sympp-mcp.cmd"), environment, clients, latencies, readyTarget);
      replacement.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "replacement", version: "1" } } })}\n`);
    } else if (mode === "backend_prebind_death") {
      const starting = await waitFor(() => { const state = readJson(runtimeFile); return state?.publication?.status === "starting" && state.publication.backend?.pid && state; }, "Pre-bind backend process was not published.");
      await terminate(Number(starting.publication.leader_pid)); fs.writeFileSync(bindReleaseFile, "ready");
      const replacement = startClient(barrier, path.join(installedRoot, "scripts", "start-sympp-mcp.cmd"), environment, clients, latencies, readyTarget);
      replacement.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "replacement", version: "1" } } })}\n`);
    }

    let readyTimeout;
    try {
      await Promise.race([allReady, new Promise((_, reject) => { readyTimeout = setTimeout(() => reject(new Error(`Only ${readyTarget.count}/${clientCount} clients completed. ${clients.map((c) => c.stderr).join("\n")}`)), 90000); })]);
    } finally {
      clearTimeout(readyTimeout);
    }
    const firstBackend = readJson(backendState);
    const firstOwnerPid = Number(readJson(runtimeFile)?.publication?.owner_adapter_pid || 0);
    const backendOnlyReadRecovery = mode.endsWith("backend_only_read_recovery");
    if (jobCertification) {
      const result = await certifyJobs({ clients, shell, runtimeFile, backendState, backendPort, traceDir, symppHome });
      backendPid = 0;
      return result;
    }
    let recoveryClients = clients;
    if (mode === "powershell_fallback_initialize_retry") {
      fs.writeFileSync(failAfterProbeFile, "ready");
      const retriedInitialize = await requestClient(clients[0], 3400, "initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "recovered-initialize", version: "1" } });
      assert.equal(retriedInitialize.result?.protocolVersion, "2025-03-26", `Provably unsent initialize was not retransmitted. ${JSON.stringify(retriedInitialize)}`);
      await waitFor(() => readJson(backendState)?.starts === 2, "Initialize retry did not elect one replacement backend.");
      for (const client of clients) client.child.stdin.end();
      const results = await Promise.all(clients.map((client) => client.result));
      assert.ok(results.every((result) => result.code === 0), results.map((result) => result.stderr).join("\n"));
      await waitFor(() => portAvailable(backendPort), "Initialize-retry replacement listener did not stop.");
      const backend = readJson(backendState);
      assert.equal(backend.initialize, clientCount + 1);
      assert.equal(fs.readdirSync(path.join(symppHome, "runtime", "codex-plugin-leases"), { withFileTypes: true }).filter((entry) => entry.isFile()).length, 0);
      backendPid = 0;
      return { mode, shell: path.basename(shell), clients: clientCount, backends: backend.starts, initializes: backend.initialize, listeners: 0, leases_after: 0, initialize_retry: true };
    } else if (mode === "powershell_fallback_recovery") {
      await terminate(firstOwnerPid);
      await terminate(firstBackend.pid);
      await waitFor(() => clients.filter((client) => client.child.exitCode === null).length === clientCount - 1, "Fallback backend owner adapter did not exit.");
      recoveryClients = clients.filter((client) => client.child.exitCode === null);
      const recovered = await Promise.all(recoveryClients.slice(0, -1).map((client, index) => requestClient(client, 3200 + index, "tools/list")));
      recovered.push(await requestClient(recoveryClients.at(-1), 3200 + recoveryClients.length - 1, "tools/list"));
      assert.ok(recovered.every((response) => response.result?.tools?.length === expectedTools.length), `Fallback adapters did not rebind tools/list. ${JSON.stringify(recovered)} state=${JSON.stringify(readJson(backendState))} leaders=${traceCount(traceDir, "cold_leader_acquired")} enabled=${traceCount(traceDir, "fallback_recovery_enabled")} ready=${traceCount(traceDir, "fallback_backend_recovery_ready")} ${recoveryClients.map((client) => client.stderr).join("\n")}`);
      await waitFor(() => readJson(backendState)?.active_leases === recoveryClients.length, `Fallback adapters did not retain replacement backend leases. state=${JSON.stringify(readJson(backendState))}`);
      const activeBackend = readJson(backendState);
      const ownersResult = spawnSync(shell, ["-NoProfile", "-NonInteractive", "-Command", "@(Get-NetTCPConnection -LocalPort $env:FIXTURE_PORT -State Listen -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique) | ConvertTo-Json -Compress"], { env: { ...process.env, FIXTURE_PORT: String(backendPort) }, encoding: "utf8", windowsHide: true });
      assert.equal(ownersResult.status, 0, ownersResult.stderr);
      assert.deepEqual([].concat(JSON.parse(ownersResult.stdout.trim())), [activeBackend.pid]);
      await terminate(activeBackend.pid);
      const bufferedResponses = [requestClient(recoveryClients[0], 3300, "tools/list"), requestClient(recoveryClients[0], 3301, "tools/list")];
      await waitFor(() => channel.counts.manifest_attempts === 3 && traceCount(traceDir, "fallback_recovery_begin") > recoveryClients.length, "Fallback recovery did not block in test-owned manifest fetch.");
      for (const client of clients) { try { client.child.stdin.end(); } catch (_) { } }
      channel.releaseManifest();
      assert.ok((await Promise.all(bufferedResponses)).every((response) => response.result?.tools?.length === expectedTools.length), "Fallback recovery discarded buffered requests after STDIN closed.");
      const results = await Promise.all(clients.map((client) => client.result));
      assert.equal(results.filter((result) => result.code !== 0).length, 1, results.map((result) => result.stderr).join("\n"));
      const leaseDir = path.join(symppHome, "runtime", "codex-plugin-leases");
      await waitFor(() => fs.readdirSync(leaseDir, { withFileTypes: true }).filter((entry) => entry.isFile()).length === 0, "Fallback replacement backend lease files did not drain.");
      const backend = readJson(backendState);
      await waitFor(() => portAvailable(backendPort), "Fallback replacement listener did not stop.");
      const stopped = readJson(runtimeFile);
      assert.ok(stopped && (!stopped.backend?.pid || !processAlive(Number(stopped.backend.pid))), `Fallback recovery retained a managed backend. ${JSON.stringify(stopped)}`);
      assert.equal(backend.starts, 3);
      assert.equal(backend.initialize, clientCount + recoveryClients.length + 1);
      assert.equal(backend.tools_list, clientCount + recoveryClients.length + 2);
      assert.equal(traceCount(traceDir, "runtime_ready_published"), 3);
      assert.equal(traceCount(traceDir, "fallback_backend_recovery_ready"), recoveryClients.length + 1);
      assert.notEqual(Number(stopped.publication.owner_adapter_pid), firstOwnerPid);
      assert.equal(fs.readdirSync(leaseDir, { withFileTypes: true }).filter((entry) => entry.isFile()).length, 0);
      backendPid = 0;
      return { mode, shell: path.basename(shell), clients: clientCount, p95_ms: percentile(latencies, 0.95), max_ms: Math.max(...latencies), manifest: channel.counts.manifest_successes, artifact: channel.counts.archive_successes, preparations: traceCount(traceDir, "artifact_prepare_end"), backends: backend.starts, pids: 2, listeners: 0, initializes: backend.initialize, tools_list: backend.tools_list, mutations: backend.mutations, lease_peak: backend.lease_peak, leases_after: 0, recovery_leaders: traceCount(traceDir, "runtime_ready_published") - 1, fallback_recovery: true, cancelled_recovery: true };
    } else if (mode === "shutdown_during_recovery") {
      await terminate(firstBackend.pid);
      await waitFor(() => traceCount(traceDir, "backend_recovery_leader") === 1, "Heartbeat recovery did not start.");
      for (const client of clients) client.child.stdin.end();
      await waitFor(() => clients.every((client) => client.child.exitCode !== null), "Adapters did not exit after STDIO closed during recovery.", 45000);
      const results = await Promise.all(clients.map((client) => client.result));
      assert.ok(results.every((result) => result.code === 0), results.map((result) => result.stderr).join("\n"));
      const backend = readJson(backendState);
      await waitFor(() => portAvailable(backendPort), "Recovery-shutdown listener did not stop.");
      const stopped = await waitFor(() => { const value = readJson(runtimeFile); return value?.backend?.status === "stopped" && value.backend.pid === null && value; }, "Recovery-shutdown state did not reach stopped.");
      assert.ok(!processAlive(backend.pid));
      assert.ok(backend.starts <= 2);
      assert.equal(traceCount(traceDir, "runtime_ready_published"), backend.starts);
      assert.equal(traceCount(traceDir, "backend_recovery_leader"), 1);
      assert.equal(fs.readdirSync(path.join(symppHome, "runtime", "codex-plugin-leases"), { withFileTypes: true }).filter((entry) => entry.isFile()).length, 0);
      backendPid = 0;
      return { mode, shell: path.basename(shell), clients: clientCount, p95_ms: percentile(latencies, 0.95), max_ms: Math.max(...latencies), manifest: channel.counts.manifest_successes, artifact: channel.counts.archive_successes, preparations: traceCount(traceDir, "artifact_prepare_end"), backends: backend.starts, pids: backend.starts, listeners: 0, initializes: backend.initialize, tools_list: backend.tools_list, mutations: backend.mutations, lease_peak: backend.lease_peak, leases_after: 0, recovery_leaders: 1, shutdown_race: stopped.backend.status === "stopped" };
    } else if (mode === "generation_changed_recovery") {
      await terminate(firstBackend.pid);
      clients[0].child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 3000, method: "tools/list", params: {} })}\n`);
      await waitFor(() => traceCount(traceDir, "replacement_lease_attached") === 1, "Replacement lease was not attached before the generation change.");
      writeJson(path.join(sourceRoot, ".codex-marketplace-install.json"), { revision: "d".repeat(40) });
      const failed = await clients[0].result;
      assert.notEqual(failed.code, 0);
      assert.match(failed.stderr, /generation changed during backend recovery/i);
      await waitFor(() => readJson(backendState)?.active_leases === 0, "Rejected replacement backend lease did not detach.");
      for (const client of clients.slice(1)) client.child.stdin.end();
      const results = await Promise.all(clients.slice(1).map((client) => client.result));
      assert.ok(results.every((result) => result.code === 0), results.map((result) => result.stderr).join("\n"));
      await waitFor(() => portAvailable(backendPort), "Generation-rejected replacement listener did not stop.");
      const stopped = await waitFor(() => { const value = readJson(runtimeFile); return value?.backend?.status === "stopped" && value.backend.pid === null && value; }, "Generation-rejected runtime state did not reach stopped.");
      const backend = readJson(backendState);
      assert.equal(backend.starts, 2);
      assert.equal(backend.tools_list, clientCount);
      assert.equal(backend.active_leases, 0);
      assert.equal(traceCount(traceDir, "backend_recovery_leader"), 1);
      assert.equal(fs.readdirSync(path.join(symppHome, "runtime", "codex-plugin-leases"), { withFileTypes: true }).filter((entry) => entry.isFile()).length, 0);
      backendPid = 0;
      return { mode, shell: path.basename(shell), clients: clientCount, p95_ms: percentile(latencies, 0.95), max_ms: Math.max(...latencies), manifest: channel.counts.manifest_successes, artifact: channel.counts.archive_successes, preparations: traceCount(traceDir, "artifact_prepare_end"), backends: backend.starts, pids: 2, listeners: 0, initializes: backend.initialize, tools_list: backend.tools_list, mutations: backend.mutations, lease_peak: backend.lease_peak, leases_after: backend.active_leases, recovery_leaders: 1, fatal_generation: stopped.backend.status === "stopped" };
    } else if (mode === "cleanup_source_changed_recovery") {
      fs.appendFileSync(path.join(sourcePluginRoot, "scripts", "start-sympp-mcp.ps1"), "\r\n");
      await terminate(firstBackend.pid);
      clients[0].child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 3100, method: "tools/list", params: {} })}\n`);
      const failed = await clients[0].result;
      assert.notEqual(failed.code, 0);
      assert.match(failed.stderr, /cleanup scripts changed during backend recovery/i);
      await waitFor(() => readJson(backendState)?.active_leases === 0, "Cleanup-invalidated replacement backend lease did not detach.");
      for (const client of clients.slice(1)) client.child.stdin.end();
      const results = await Promise.all(clients.slice(1).map((client) => client.result));
      assert.ok(results.every((result) => result.code === 0), results.map((result) => result.stderr).join("\n"));
      await waitFor(() => portAvailable(backendPort), "Cleanup-invalidated replacement listener did not stop.");
      const stopped = await waitFor(() => { const value = readJson(runtimeFile); return value?.backend?.status === "stopped" && value.backend.pid === null && value; }, "Cleanup-invalidated runtime state did not reach stopped.");
      const backend = readJson(backendState);
      assert.equal(backend.starts, 2);
      assert.equal(backend.tools_list, clientCount);
      assert.equal(backend.active_leases, 0);
      assert.equal(traceCount(traceDir, "replacement_lease_attached"), 1);
      assert.equal(fs.readdirSync(path.join(symppHome, "runtime", "codex-plugin-leases"), { withFileTypes: true }).filter((entry) => entry.isFile()).length, 0);
      backendPid = 0;
      return { mode, shell: path.basename(shell), clients: clientCount, p95_ms: percentile(latencies, 0.95), max_ms: Math.max(...latencies), manifest: channel.counts.manifest_successes, artifact: channel.counts.archive_successes, preparations: traceCount(traceDir, "artifact_prepare_end"), backends: backend.starts, pids: 2, listeners: 0, initializes: backend.initialize, tools_list: backend.tools_list, mutations: backend.mutations, lease_peak: backend.lease_peak, leases_after: backend.active_leases, recovery_leaders: traceCount(traceDir, "backend_recovery_leader"), fatal_cleanup: stopped.backend.status === "stopped" };
    } else if (mode === "backend_loss") {
      await terminate(firstBackend.pid);
    } else if (mode === "owner_loss") {
      await terminate(firstOwnerPid);
      await terminate(firstBackend.pid);
      await waitFor(() => clients.filter((client) => client.child.exitCode === null).length === clientCount - 1, "Backend owner adapter did not exit.");
      recoveryClients = clients.filter((client) => client.child.exitCode === null);
    } else if (backendOnlyReadRecovery) {
      fs.writeFileSync(failReadFile, "ready");
      const recovered = mode.startsWith("powershell_fallback")
        ? await requestClientLine(clients[0], 3500, '{"jsonrpc":"2.0","id":3500,"method":"tools/list","Method":"other","params":{}}')
        : await requestClient(clients[0], 3500, "tools/list");
      assert.equal(recovered.result?.tools?.length, expectedTools.length, `Read-only request was not retried after backend exit. ${JSON.stringify(recovered)}`);
    }
    if (["backend_loss", "owner_loss"].includes(mode)) {
      const recovered = await Promise.all(recoveryClients.map((client, index) => requestClient(client, 1000 + index, "tools/list")));
      assert.ok(recovered.every((response) => response.result?.tools?.length === expectedTools.length), "Surviving adapters did not rebind tools/list.");
    } else if (mode.endsWith("ambiguous_tool")) {
      const indeterminate = mode.startsWith("powershell_fallback")
        ? await requestClientLine(clients[0], 2000, JSON.stringify({ jsonrpc: "2.0", id: 2000, method: "tools/call", Method: "other", params: { name: "fixture.mutate", arguments: { padding: "x".repeat(2_100_000) } } }))
        : await requestClient(clients[0], 2000, "tools/call", { name: "fixture.mutate", arguments: {} });
      assert.equal(indeterminate.id, 2000);
      assert.equal(indeterminate.error?.code, -32001);
      assert.equal(indeterminate.error?.data?.replayed, false);
      const recovered = await requestClient(clients[0], 2001, "tools/list");
      assert.equal(recovered.result?.tools?.length, expectedTools.length);
    }
    if (["backend_loss", "owner_loss"].includes(mode) || mode.endsWith("ambiguous_tool") || backendOnlyReadRecovery) {
      const expectedRecoveredLeases = mode.endsWith("ambiguous_tool") || backendOnlyReadRecovery ? 1 : recoveryClients.length;
      await waitFor(() => readJson(backendState)?.active_leases === expectedRecoveredLeases, "Recovered adapters did not retain their replacement backend leases.");
    }
    const activeBackend = readJson(backendState);
    const ownersResult = spawnSync(shell, ["-NoProfile", "-NonInteractive", "-Command", "@(Get-NetTCPConnection -LocalPort $env:FIXTURE_PORT -State Listen -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique) | ConvertTo-Json -Compress"], { env: { ...process.env, FIXTURE_PORT: String(backendPort) }, encoding: "utf8", windowsHide: true });
    assert.equal(ownersResult.status, 0, ownersResult.stderr);
    assert.deepEqual([].concat(JSON.parse(ownersResult.stdout.trim())), [activeBackend.pid]);
    for (const client of clients) { try { client.child.stdin.end(); } catch (_) { } }
    const results = await Promise.all(clients.map((client) => client.result));
    const expectedFailures = mode.endsWith("_death") || mode === "owner_loss" ? 1 : 0;
    assert.equal(results.filter((result) => result.code !== 0).length, expectedFailures, results.map((result) => result.stderr).join("\n"));
    assert.equal(results.filter((result) => result.code === 0).length, results.length - expectedFailures);
    await waitFor(() => readJson(backendState)?.active_leases === 0, "Backend leases did not drain.");
    const backend = readJson(backendState);
    backendPid = backend.pid;
    await waitFor(() => portAvailable(backendPort), "Backend listener did not stop after the final client exited.");
    const state = await waitFor(() => { const value = readJson(runtimeFile); return value?.backend?.status === "stopped" && value.backend.pid === null && value; }, "Runtime state did not record zero-client backend shutdown.");
    assert.equal(state.publication.status, "ready");
    const recoveryMode = ["backend_loss", "owner_loss"].includes(mode) || mode.endsWith("ambiguous_tool") || backendOnlyReadRecovery;
    const recoveryRebinds = ["backend_loss", "owner_loss"].includes(mode) ? recoveryClients.length : mode.endsWith("ambiguous_tool") || backendOnlyReadRecovery ? 1 : 0;
    assert.equal(backend.starts, recoveryMode ? 2 : 1);
    assert.equal(backend.initialize, clientCount + recoveryRebinds);
    assert.equal(backend.tools_list, clientCount + recoveryRebinds + (backendOnlyReadRecovery ? 1 : 0));
    assert.equal(backend.mutations, mode.endsWith("ambiguous_tool") ? 1 : 0);
    assert.equal(backend.lease_peak, clientCount);
    assert.equal(backend.active_leases, 0);
    assert.equal(fs.readdirSync(path.join(symppHome, "runtime", "codex-plugin-leases"), { withFileTypes: true }).filter((entry) => entry.isFile()).length, 0);
    assert.equal(channel.counts.manifest_successes, mode === "artifact_death" || recoveryMode ? 2 : 1);
    assert.equal(channel.counts.archive_successes, 1);
    assert.equal(traceCount(traceDir, "artifact_prepare_end"), 1);
    assert.equal(traceCount(traceDir, "runtime_ready_published"), recoveryMode ? 2 : 1);
    const recoveryLeaders = recoveryMode && mode.startsWith("powershell_fallback") ? traceCount(traceDir, "runtime_ready_published") - 1 : traceCount(traceDir, "backend_recovery_leader");
    assert.equal(recoveryLeaders, recoveryMode ? 1 : 0);
    if (recoveryMode) {
      assert.notEqual(activeBackend.pid, firstBackend.pid);
    }
    if (mode === "owner_loss") assert.notEqual(Number(state.publication.owner_adapter_pid), firstOwnerPid);
    if (mode === "normal") assert.deepEqual(channel.counts, { manifest_attempts: 1, manifest_successes: 1, archive_attempts: 1, archive_successes: 1 });
    if (mode === "manifest_death") assert.equal(channel.counts.manifest_attempts, 2);
    if (mode === "artifact_death") assert.equal(channel.counts.archive_attempts, 2);
    if (["backend_death", "backend_prebind_death"].includes(mode)) assert.equal(traceCount(traceDir, "backend_adopted"), 1);
    if (mode === "powershell_fallback") {
      assert.equal(traceCount(traceDir, "installed_identity_full_validation"), 1);
      assert.ok(traceOrder(traceDir, "cold_leader_acquired", "installed_identity_full_validation"));
    }
    const cacheRoot = path.dirname(state.artifact.root);
    assertLockFree(shell, path.join(path.dirname(runtimeFile), "codex-plugin.lock"), path.join(cacheRoot, "artifact.lock"));
    const leftovers = [];
    for (const directory of [symppHome, environment.TEMP]) if (fs.existsSync(directory)) for (const entry of fs.readdirSync(directory, { recursive: true })) if (/artifact\.zip\.tmp-|\.extracting-|codex-plugin\.json\.tmp-/.test(String(entry))) leftovers.push(entry);
    assert.deepEqual(leftovers, []);
    assert.ok(percentile(latencies, 0.95) < 60000 && Math.max(...latencies) < 90000);
    return { mode, shell: path.basename(shell), clients: clientCount, p95_ms: percentile(latencies, 0.95), max_ms: Math.max(...latencies), manifest: channel.counts.manifest_successes, manifest_attempts: channel.counts.manifest_attempts, artifact: channel.counts.archive_successes, artifact_attempts: channel.counts.archive_attempts, preparations: traceCount(traceDir, "artifact_prepare_end"), backends: backend.starts, pids: recoveryMode ? 2 : 1, listeners: 0, initializes: backend.initialize, tools_list: backend.tools_list, mutations: backend.mutations, lease_peak: backend.lease_peak, leases_after: backend.active_leases, adopted: traceCount(traceDir, "backend_adopted"), recovery_leaders: recoveryLeaders };
  } finally {
    terminateTrees(clients.filter((client) => client.child.exitCode === null).map((client) => client.child.pid));
    if (!backendPid) backendPid = readJson(backendState)?.pid || 0;
    await stopBackend(backendPort, backendPid);
    if (channel) { channel.server.closeAllConnections?.(); await new Promise((resolve) => channel.server.close(resolve)); }
    await removeTree(root);
  }
}

async function main() {
  const pwsh = spawnSync("where.exe", ["pwsh.exe"], { encoding: "utf8" }).stdout.trim().split(/\r?\n/)[0];
  const windowsPowerShell = spawnSync("where.exe", ["powershell.exe"], { encoding: "utf8" }).stdout.trim().split(/\r?\n/)[0];
  assert.ok(pwsh && windowsPowerShell, "Both pwsh and Windows PowerShell 5.1 are required.");
  if (process.env.SYMPP_COLD_ONLY) {
    const result = await runCase(Number(process.env.SYMPP_COLD_CLIENTS || 3), process.env.SYMPP_COLD_SHELL === "powershell" ? windowsPowerShell : pwsh, process.env.SYMPP_COLD_ONLY);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }
  if (process.env.SYMPP_JOB_CERTIFICATION) {
    const result = await runCase(32, pwsh, "job_certification");
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }
  const results = [];
  results.push(await runCase(30, windowsPowerShell));
  results.push(await runCase(100, pwsh));
  results.push(await runCase(200, pwsh));
  const powershellFallback = await runCase(30, windowsPowerShell, "powershell_fallback");
  for (const mode of ["manifest_death", "artifact_death", "backend_death", "backend_prebind_death"]) results.push(await runCase(30, pwsh, mode));
  const recovery = [];
  for (const mode of ["owner_loss", "backend_loss", "backend_only_read_recovery", "ambiguous_tool", "powershell_fallback_ambiguous_tool", "shutdown_during_recovery", "generation_changed_recovery", "cleanup_source_changed_recovery", "powershell_fallback_recovery", "powershell_fallback_backend_only_read_recovery", "powershell_fallback_initialize_retry"]) recovery.push(await runCase(["shutdown_during_recovery", "generation_changed_recovery", "cleanup_source_changed_recovery"].includes(mode) ? 3 : mode === "powershell_fallback_recovery" ? 4 : mode.endsWith("backend_only_read_recovery") || mode.endsWith("ambiguous_tool") || mode === "powershell_fallback_initialize_retry" ? 1 : 10, mode.startsWith("powershell_fallback") ? windowsPowerShell : pwsh, mode));
  process.stdout.write(`${JSON.stringify({ matrix: results.slice(0, 3), powershell_fallback: powershellFallback, leader_death: results.slice(3), recovery, powershell_5_1: true, pwsh: true, cleanup: true })}\n`);
}

if (process.argv[2] === "--barrier-client") barrierClient().catch((error) => { process.stderr.write(`${error.stack || error}\n`); process.exit(1); });
else main().catch((error) => { process.stderr.write(`${error.stack || error}\n`); process.exit(1); });
