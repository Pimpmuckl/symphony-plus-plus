#!/usr/bin/env node
/* global console, process */
import { createRequire } from "node:module";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const require = createRequire(path.join(repoRoot, "elixir/assets/package.json"));
const { chromium } = require("playwright");
const url = option("url") || "http://127.0.0.1:20051/sympp/board";
const samples = Number(option("samples") || 10);
const details = process.argv.includes("--details");

if (!Number.isInteger(samples) || samples < 1) throw new Error("--samples must be a positive integer");

const browser = await chromium.launch({ headless: true });
const results = [];

try {
  for (let index = 0; index < samples; index += 1) results.push(await measureSample(browser));
} finally {
  await browser.close();
}

console.log(JSON.stringify(summarize(results), null, 2));

async function measureSample(browser) {
  const context = await browser.newContext({ reducedMotion: "reduce", viewport: { width: 1440, height: 1000 } });
  await context.addInitScript(() => {
    localStorage.setItem("symphony-plus-plus.dashboard.ui-state.v1", JSON.stringify({
      focusBoardSections: { active: true, attention: true, next: true, recent: true, waiting: true },
      showWelcomeToast: false,
    }));
  });

  const page = await context.newPage();
  const requests = [];
  const requestStarts = new WeakMap();

  page.on("request", (request) => requestStarts.set(request, performance.now()));
  page.on("response", (response) => {
    if (!dashboardSnapshotPath(response.url())) return;
    const request = response.request();
    const startedAt = requestStarts.get(request) ?? performance.now();
    requests.push(recordResponse(response, startedAt));
  });

  const coldStartedAt = performance.now();
  const deferredResponsePromise = page.waitForResponse((response) => dashboardSnapshotPath(response.url()) === "/dashboard/deferred");
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
  const focusBoard = page.locator(".focus-board");
  await focusBoard.waitFor({ state: "visible", timeout: 30_000 });
  await focusBoard.locator(".v3-request-row").first().waitFor({ state: "attached", timeout: 30_000 });
  await paint(page);
  const coldUsableMs = performance.now() - coldStartedAt;
  const deferredResponse = await deferredResponsePromise;
  await deferredResponse.finished();
  const coldRequests = await settledRequests(requests);

  const largeRequest = focusBoard.locator('[data-request-id="WR-FIXTURE-KRAKEN-SCALE"]');
  const expandStartedAt = performance.now();
  await largeRequest.getByRole("button", { name: /^Expand / }).click();
  const largeGraph = page.locator('.focus-board[data-focus-request-id="WR-FIXTURE-KRAKEN-SCALE"][data-focus-phase="focused"] .execution-graph');
  await largeGraph.locator(".execution-graph__card").first().waitFor({ state: "visible" });
  await paint(page);
  const expandLargeGraphMs = performance.now() - expandStartedAt;

  const collapseStartedAt = performance.now();
  await focusBoard.locator('[data-request-id="WR-FIXTURE-KRAKEN-SCALE"]').getByRole("button", { name: /^Collapse / }).click();
  await page.locator('.focus-board[data-focus-request-id="WR-FIXTURE-KRAKEN-SCALE"]').waitFor({ state: "detached" });
  await paint(page);
  const collapseLargeGraphMs = performance.now() - collapseStartedAt;

  const refreshButton = page.getByRole("button", { name: "Refresh", exact: true });
  const refreshStartedAt = performance.now();
  const refreshResponsePromise = page.waitForResponse((response) => dashboardSnapshotPath(response.url()) === "/dashboard");
  const refreshDeferredPromise = page.waitForResponse((response) => dashboardSnapshotPath(response.url()) === "/dashboard/deferred");
  await refreshButton.click();
  const refreshResponse = await refreshResponsePromise;
  const refreshDeferred = await refreshDeferredPromise;
  await Promise.all([refreshResponse.finished(), refreshDeferred.finished()]);
  await refreshButton.waitFor({ state: "visible" });
  await page.waitForFunction(() =>
    [...document.querySelectorAll("button")].some((button) => button.textContent?.includes("Refresh") && !button.disabled),
  );
  await paint(page);
  const refreshUsableMs = performance.now() - refreshStartedAt;
  const allRequests = await settledRequests(requests);
  const refreshRequests = allRequests.slice(coldRequests.length);

  await context.close();

  return {
    cold: {
      api_ms: batchDuration(coldRequests),
      browser_usable_ms: coldUsableMs,
      bytes: sum(coldRequests.map((request) => request.bytes)),
      request_count: coldRequests.length,
      paths: coldRequests.map((request) => request.path),
    },
    focus_board: {
      collapse_large_graph_ms: collapseLargeGraphMs,
      expand_large_graph_ms: expandLargeGraphMs,
      first_usable_ms: coldUsableMs,
    },
    refresh: {
      api_ms: batchDuration(refreshRequests),
      browser_usable_ms: refreshUsableMs,
      bytes: sum(refreshRequests.map((request) => request.bytes)),
      request_count: refreshRequests.length,
      paths: refreshRequests.map((request) => request.path),
    },
  };
}

async function recordResponse(response, startedAt) {
  await response.finished();
  const body = await response.body();
  return {
    bytes: body.byteLength,
    finishedAt: performance.now(),
    ms: performance.now() - startedAt,
    path: dashboardSnapshotPath(response.url()),
    startedAt,
  };
}

async function settledRequests(requests) {
  return Promise.all(requests);
}

function dashboardSnapshotPath(rawUrl) {
  const pathname = new URL(rawUrl).pathname;
  const prefix = "/api/v1/sympp/operator";
  if (!pathname.startsWith(`${prefix}/dashboard`)) return null;
  const path = pathname.slice(prefix.length);
  return ["/dashboard", "/dashboard/deferred", "/dashboard/hydrated"].includes(path) ? path : null;
}

function batchDuration(requests) {
  return Math.max(...requests.map((request) => request.finishedAt)) - Math.min(...requests.map((request) => request.startedAt));
}

function summarize(results) {
  return {
    samples: results.length,
    cold: summarizeMode(results.map((result) => result.cold)),
    focus_board: summarizeJourney(results.map((result) => result.focus_board)),
    refresh: summarizeMode(results.map((result) => result.refresh)),
  };
}

function summarizeJourney(results) {
  const summary = Object.fromEntries(Object.keys(results[0]).map((key) => [`${key}_p50`, median(results.map((result) => result[key]))]));
  return details ? { ...summary, samples: results } : summary;
}

function summarizeMode(results) {
  const summary = {
    api_ms_p50: median(results.map((result) => result.api_ms)),
    browser_usable_ms_p50: median(results.map((result) => result.browser_usable_ms)),
    bytes_p50: median(results.map((result) => result.bytes)),
    request_count: results[0].request_count,
    paths: results[0].paths,
  };

  return details ? { ...summary, samples: results } : summary;
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function sum(values) {
  return values.reduce((total, value) => total + value, 0);
}

async function paint(page) {
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

function option(name) {
  const key = `--${name}`;
  const index = process.argv.indexOf(key);
  if (index !== -1) return process.argv[index + 1];
  const prefix = `${key}=`;
  return process.argv.find((argument) => argument.startsWith(prefix))?.slice(prefix.length);
}
