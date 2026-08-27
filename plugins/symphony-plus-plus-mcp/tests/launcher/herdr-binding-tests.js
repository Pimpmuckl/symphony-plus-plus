"use strict";

const assert = require("assert/strict");
const path = require("path");
const { decodeHerdrBinding, herdrMetadataArgs } = require(path.resolve(__dirname, "../../scripts/start-sympp-mcp-bridge.js"));

const encoded = Buffer.from(JSON.stringify({ role: "worker", work_package_id: "wp-test", show_inspector: false })).toString("base64url");
const binding = decodeHerdrBinding(encoded);
const args = herdrMetadataArgs(binding, "http://127.0.0.1:19998/");

assert.equal(decodeHerdrBinding("clear"), null);
assert.ok(args.includes("sympp_role=worker"));
assert.ok(args.includes("sympp_work_package_id=wp-test"));
assert.ok(args.includes("sympp_show_inspector=false"));
assert.ok(args.includes("sympp_endpoint=http://127.0.0.1:19998"));
assert.ok(args.includes("sympp_work_request_id"));

process.stdout.write("Herdr binding adapter tests passed.\n");
