"use strict";

const assert = require("assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { generationFromMarker, generationKey, resolveStateIdentity } = require("../../scripts/start-sympp-mcp-bridge.js");

const pluginRoot = path.resolve("test-installed/codex/plugins/cache/marketplace/symphony-plus-plus-mcp/0.1.9");
const contract = "a".repeat(64);
const revision = "b".repeat(40);
const backend = "http://127.0.0.1:19998";
const runtimeKey = `contract=${contract};backend=${backend};dashboard=${backend}`;
const identity = {
  contract_fingerprint: contract,
  revision,
  source_root: path.resolve("test-marketplace-source"),
  generation_key: "c".repeat(64),
  generation_marker: "marker",
  generation_watch_version: 1,
};

assert.equal(generationFromMarker({ generation_key: identity.generation_key, validated_at_ms: 200 }, 100), identity.generation_key);
assert.equal(generationFromMarker({ generation_key: identity.generation_key, validated_at_ms: 99 }, 100), null,
  "a new attach must not trust generation validation from before its watcher boundary");
assert.equal(generationFromMarker({ generation_key: "invalid", validated_at_ms: 200 }, 100), null);
const state = {
  plugin_root: pluginRoot,
  runtime_key: runtimeKey,
  runtime_kind: "external_loopback",
  runtime_mode: "artifact",
  backend: {
    status: "external_loopback",
    url: backend,
    managed: false,
    pid: null,
    source_revision: revision,
    expected_contract_fingerprint: contract,
    contract_fingerprint: contract,
  },
  frontend: { status: "artifact_static", origin: backend, managed: false, pid: null },
};

function changed(update) {
  const copy = structuredClone(state);
  update(copy);
  return copy;
}

const resolved = resolveStateIdentity(state, pluginRoot, identity);
assert.ok(resolved, "cutover external backend with artifact frontend must use the Node bridge");
assert.equal(resolved.revision, revision, "installed revision identity must be preserved");
assert.equal(resolved.contract, contract, "installed contract identity must be preserved");
assert.equal(resolved.pluginRoot, pluginRoot, "installed plugin root must remain available for final attachment validation");
assert.equal(resolved.sourceRoot, identity.source_root, "marketplace root must remain available for final attachment validation");

assert.equal(resolveStateIdentity(changed((value) => { value.backend.status = "started"; }), pluginRoot, identity), null);
assert.equal(resolveStateIdentity(changed((value) => { value.frontend.managed = true; }), pluginRoot, identity), null);
assert.equal(resolveStateIdentity(changed((value) => { value.runtime_mode = "external"; }), pluginRoot, identity), null);
assert.equal(resolveStateIdentity(changed((value) => { value.backend.expected_contract_fingerprint = "d".repeat(64); }), pluginRoot, identity), null);
assert.equal(resolveStateIdentity(changed((value) => { value.backend.url = "http://example.com:19998"; }), pluginRoot, identity), null);
assert.equal(resolveStateIdentity(changed((value) => { value.frontend.origin = "http://example.com:19998"; }), pluginRoot, identity), null);
assert.equal(resolveStateIdentity(changed((value) => { value.runtime_key = "wrong"; }), pluginRoot, identity), null);
assert.equal(resolveStateIdentity(state, path.join(pluginRoot, "other"), identity), null);
assert.equal(resolveStateIdentity(state, pluginRoot, null), null);

const marketplaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-node-marketplace-"));
try {
  const installedRoot = path.join(marketplaceRoot, "installed");
  const sourceRoot = path.join(marketplaceRoot, "source");
  fs.mkdirSync(installedRoot, { recursive: true });
  fs.mkdirSync(path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus"), { recursive: true });
  fs.writeFileSync(path.join(sourceRoot, ".codex-marketplace-install.json"), JSON.stringify({ revision }));
  fs.writeFileSync(
    path.join(sourceRoot, "elixir", "priv", "symphony_plus_plus", "mcp_contract.json"),
    JSON.stringify({ mcp_contract_fingerprint: contract }),
  );
  const first = generationKey(installedRoot, sourceRoot);
  assert.match(first, /^[0-9a-f]{64}$/, "Codex marketplace metadata must identify a marker-free install");
  fs.writeFileSync(path.join(installedRoot, "payload.txt"), "locally changed");
  assert.equal(
    generationKey(installedRoot, sourceRoot),
    first,
    "Node warm attach must trust the Codex-owned installed cache instead of hashing every file",
  );
} finally {
  fs.rmSync(marketplaceRoot, { recursive: true, force: true });
}

process.stdout.write("Node cutover state identity tests passed.\n");
