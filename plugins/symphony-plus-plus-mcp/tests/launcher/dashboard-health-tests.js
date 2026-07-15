"use strict";

const assert = require("assert/strict");
const http = require("http");
const { dashboardHealthy } = require("../../scripts/start-sympp-mcp-bridge.js");

const servers = [];

async function listen(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  servers.push(server);
  return `http://127.0.0.1:${server.address().port}`;
}

function redirect(location) {
  return (_request, response) => {
    response.writeHead(302, location === undefined ? {} : { Location: location });
    response.end();
  };
}

function identity(origin) {
  return { backend: origin, dashboard: origin, headless: false };
}

async function main() {
  const dashboard = await listen((_request, response) => response.end("<title>Symphony++ Dashboard</title>"));
  const proxy = await listen(redirect(`${dashboard}/sympp/board`));
  assert.equal(await dashboardHealthy(identity(proxy)), true, "loopback dashboard redirect must be healthy");

  const invalidDashboard = await listen((_request, response) => response.end("not the dashboard"));
  const invalidBodyProxy = await listen(redirect(`${invalidDashboard}/sympp/board`));
  assert.equal(await dashboardHealthy(identity(invalidBodyProxy)), false, "redirect target must contain the dashboard body");

  for (const location of [undefined, "http://example.com/sympp/board", "https://127.0.0.1/sympp/board", "http://user:pass@127.0.0.1/sympp/board", "http://[::1"]) {
    const unsafeProxy = await listen(redirect(location));
    assert.equal(await dashboardHealthy(identity(unsafeProxy)), false, `unsafe redirect must fail: ${location}`);
  }

  let loopOrigin;
  loopOrigin = await listen((request, response) => redirect(`${loopOrigin}/sympp/board`)(request, response));
  assert.equal(await dashboardHealthy(identity(loopOrigin)), false, "redirect loop must fail");

  const chain = await listen((request, response) => {
    const match = /^\/redirect-(\d+)$/.exec(request.url);
    const step = match ? Number(match[1]) : 0;
    if (step < 4) return redirect(`/redirect-${step + 1}`)(request, response);
    response.end("<title>Symphony++ Dashboard</title>");
  });
  assert.equal(await dashboardHealthy(identity(chain)), false, "redirect chain must be bounded");
}

main().then(() => {
  process.stdout.write("Node dashboard health tests passed.\n");
}).finally(async () => {
  for (const server of servers) {
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
  }
}).catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
