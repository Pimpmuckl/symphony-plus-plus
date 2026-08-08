import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import { chromium, type Browser } from "playwright";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type ViteDevServer } from "vite";
import { DASHBOARD_UI_STATE_KEY } from "./runtime";

let browser: Browser;
let server: ViteDevServer;
let url: string;

beforeAll(async () => {
  server = await createServer({
    configFile: path.resolve("vite.config.ts"),
    server: { port: 0, strictPort: false },
  });
  await server.listen();
  url = server.resolvedUrls!.local[0];
  browser = await chromium.launch({ executablePath: browserExecutablePath() });
});

afterAll(async () => {
  await browser?.close();
  await server?.close();
}, 20_000);

describe("focus board interactions", () => {
  it("paints the application shell and consumes the config bootstrap without a priority waterfall", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    let releaseConfig!: () => void;
    const configReady = new Promise<void>((resolve) => { releaseConfig = resolve; });
    let priorityRequests = 0;

    await page.route("**/api/v1/sympp/operator/config*", async (route) => {
      await configReady;
      await route.fulfill({ json: { apiBase: "/api/v1/sympp/operator", operatorMode: false, dashboard: priorityDashboard } });
    });
    await page.route("**/api/v1/sympp/operator/dashboard", (route) => {
      priorityRequests += 1;
      return route.fulfill({ json: priorityDashboard });
    });
    await page.route("**/api/v1/sympp/operator/dashboard/deferred", (route) => route.fulfill({ json: deferredDashboard }));
    await page.route("**/api/v1/sympp/operator/work-requests/wr-interaction*", (route) => route.fulfill({ json: deferredDashboard.work_request_details[0] }));
    await page.route("**/api/v1/sympp/operator/dashboard/events", (route) => route.abort());

    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
    await page.getByRole("heading", { name: "Symphony++" }).waitFor();
    expect(await page.getByLabel("Loading workstreams").isVisible()).toBe(true);
    expect(await page.getByText("Loading Symphony++").count()).toBe(0);

    releaseConfig();
    await page.getByText("Interaction request", { exact: true }).waitFor();
    expect(priorityRequests).toBe(0);
    await page.keyboard.press("Escape");
    await page.locator('[data-request-id="wr-interaction"]').first().getByRole("button", { name: "Open request details" }).click();
    const detail = page.locator(".dashboard-dialog-content");
    await detail.getByText("Mark Delivered", { exact: true }).waitFor();
    expect(await detail.getByText("Add Comment", { exact: true }).count()).toBe(1);
    expect(await detail.getByText("Delete Request", { exact: true }).count()).toBe(1);
    await page.close();
  }, 20_000);

  it("toggles the docked workbench and keeps it stable while selection swaps", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    await enableFocusBoard(page);
    page.setDefaultTimeout(3_000);
    let releaseDeferred!: () => void;
    const deferredReady = new Promise<void>((resolve) => {
      releaseDeferred = resolve;
    });
    let markDeferredRequested!: () => void;
    const deferredRequested = new Promise<void>((resolve) => {
      markDeferredRequested = resolve;
    });
    const requests: string[] = [];

    await page.route("**/api/v1/sympp/operator/config*", (route) =>
      route.fulfill({ json: { apiBase: "/api/v1/sympp/operator", basePath: "/sympp/board" } }),
    );
    await page.route("**/api/v1/sympp/operator/dashboard/events", (route) => route.abort());
    await page.route("**/api/v1/sympp/operator/dashboard", async (route) => {
      requests.push("priority");
      await route.fulfill({ json: priorityDashboard });
    });
    await page.route("**/api/v1/sympp/operator/dashboard/deferred", async (route) => {
      requests.push("deferred");
      markDeferredRequested();
      await deferredReady;
      await route.fulfill({ json: deferredDashboard });
    });

    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
    const board = page.locator(".focus-board");
    await board.waitFor({ state: "attached" });
    await deferredRequested;
    expect(requests).toEqual(["priority", "deferred"]);
    expect(await board.getAttribute("aria-busy")).toBe("true");
    expect(await board.getByText("Loading latest activity…", { exact: true }).isVisible()).toBe(true);
    expect(await board.getByText(/open across repositories/).count()).toBe(0);
    expect(await board.getByRole("region", { name: /Moving now/ }).count()).toBe(0);
    expect(await page.locator('.workstream-repo-card [data-request-id="wr-interaction"]').count()).toBe(1);

    releaseDeferred();
    await board.locator('[data-request-id="wr-interaction"]').waitFor({ state: "attached" });
    await board.getByText("3 open across repositories", { exact: true }).waitFor();
    expect(await board.getByText("Loading latest activity…", { exact: true }).count()).toBe(0);
    const workbench = board.locator(".focus-board__workbench");
    const selected = board.locator('[data-request-id="wr-following-group"]');
    const next = board.locator('[data-request-id="wr-interaction"]');
    await workbench.getByText("Following group request", { exact: true }).waitFor();
    await page.keyboard.press("Escape");
    await page.locator(".dialog-overlay").waitFor({ state: "hidden" });
    expect(await selected.locator(".v3-request-main").getAttribute("aria-pressed")).toBe("true");
    expect(await workbench.getAttribute("data-mode")).toBe("frontier");
    expect(await board.locator(".focus-board__shelf-row").evaluateAll((rows) => rows.every((row) => row.scrollWidth === row.clientWidth))).toBe(true);
    expect(await board.locator(".focus-board__shelf-row .v3-request-row").evaluateAll((cards) => cards.every((card) => card.scrollHeight === card.clientHeight))).toBe(true);
    const graphViewport = workbench.locator(".execution-graph__viewport");
    await graphViewport.waitFor();
    expect(await graphViewport.evaluate((element) => getComputedStyle(element).scrollbarWidth)).toBe("none");
    expect(await board.locator(".focus-board__workbench-reveal").evaluate((element) => getComputedStyle(element).viewTransitionName)).toBe("focus-workbench");
    const before = await workbench.evaluate((element) => ({ height: element.getBoundingClientRect().height, top: element.getBoundingClientRect().top, scrollY }));

    const fullMap = workbench.getByRole("button", { name: "Full map" });
    await page.waitForFunction(() => !document.querySelector<HTMLButtonElement>('.focus-board__mode-switch button:last-child')?.disabled);
    await fullMap.click();
    expect(await workbench.getAttribute("data-mode")).toBe("full");
    await next.locator(".v3-request-main").click();

    expect(await board.getAttribute("data-focus-request-id")).toBe("wr-interaction");
    expect(await next.locator(".v3-request-main").getAttribute("aria-pressed")).toBe("true");
    expect(await workbench.getByText("Interaction request", { exact: true }).isVisible()).toBe(true);
    await page.waitForFunction(() => document.querySelector(".focus-board__workbench")?.getAttribute("data-mode") === "frontier");
    expect(await workbench.getAttribute("data-mode")).toBe("frontier");
    expect(await board.getAttribute("data-focus-phase")).toBeNull();
    const after = await workbench.evaluate((element) => ({ height: element.getBoundingClientRect().height, top: element.getBoundingClientRect().top, scrollY }));
    expect(after.top).toBe(before.top);
    expect(after.scrollY).toBe(before.scrollY);
    expect(after.height).toBeGreaterThan(0);

    await next.locator(".v3-request-main").click();
    expect(await board.getAttribute("data-focus-request-id")).toBeNull();
    expect(await next.locator(".v3-request-main").getAttribute("aria-pressed")).toBe("false");
    await page.waitForFunction(() => document.querySelector(".focus-board__workbench-reveal")?.getAttribute("data-open") === "false");
    expect(await board.locator(".focus-board__workbench-reveal").getAttribute("data-open")).toBe("false");

    await next.locator(".v3-request-main").click();
    expect(await board.getAttribute("data-focus-request-id")).toBe("wr-interaction");
    await page.waitForFunction(() => document.querySelector(".focus-board__workbench-reveal")?.getAttribute("data-open") === "true");
    expect(await board.locator(".focus-board__workbench-reveal").getAttribute("data-open")).toBe("true");

    await page.close();
  }, 20_000);

  it("closes the blocker overview and modal when jumping to its WorkPackage", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    await enableFocusBoard(page);
    page.setDefaultTimeout(5_000);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.route("**/api/v1/sympp/operator/config*", (route) =>
      route.fulfill({ json: { apiBase: "/api/v1/sympp/operator", basePath: "/sympp/board" } }),
    );
    await page.route("**/api/v1/sympp/operator/dashboard/events", (route) => route.abort());
    await page.route("**/api/v1/sympp/operator/dashboard", (route) => route.fulfill({ json: attentionDashboard }));
    await page.route("**/api/v1/sympp/operator/work-packages/wp-jump", (route) => route.fulfill({
      json: { work_package: attentionPackage, blockers: [attentionBlocker] },
    }));
    await page.route("**/api/v1/sympp/operator/work-requests/wr-jump*", (route) => route.fulfill({
      json: attentionDashboard.work_request_details[0],
    }));

    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
    await page.waitForTimeout(500);
    const attentionLabels = await page.locator(".dashboard-attention-button").evaluateAll((buttons) => buttons.map((button) => button.getAttribute("aria-label")));
    expect({ attentionLabels, text: await page.locator("body").innerText() }).toMatchObject({
      attentionLabels: expect.arrayContaining(["Active Blockers: 1"]),
    });
    await page.keyboard.press("Escape");
    await page.locator(".dialog-overlay").waitFor({ state: "hidden" });
    await page.getByRole("button", { name: "Active Blockers: 1" }).click();
    const panel = page.locator(".top-panel-inline");
    await panel.locator(".attention-location__repo:visible").waitFor();
    await page.waitForFunction(() => document.querySelector(".top-panel-viewport")?.getAttribute("data-phase") === "idle");
    expect(await panel.locator(".top-panel-static").count()).toBe(1);
    expect(await panel.locator(".top-panel-track").count()).toBe(0);
    const panelText = await panel.textContent();
    expect(panelText).toContain("Jump request");
    expect(panelText).toContain("Jump group – Jump package");
    expect(panelText).toContain("Blocked for 3h");
    expect(panelText).not.toContain("since");
    expect(panelText).not.toContain("Open blocker");
    expect(await panel.getByRole("button", { name: "Jump to Jump request" }).innerText()).toBe("WR");

    await panel.getByRole("button", { name: /Open Blocked/ }).click();
    const modal = page.locator(".attention-dialog");
    await modal.getByTitle("Jump to Jump package").waitFor();
    expect(await modal.textContent()).toContain("Jump group – Jump package");
    await modal.getByTitle("Jump to Jump package").click();

    await modal.waitFor({ state: "hidden" });
    await page.waitForFunction(() => document.querySelector(".top-panel-inline")?.getAttribute("data-open-panel") === "none");
    await page.waitForFunction(() => document.querySelector(".focus-board__workbench")?.getAttribute("data-mode") === "full");
    expect(await page.locator(".focus-board").getAttribute("data-focus-request-id")).toBe("wr-jump");
    const target = page.locator('.execution-graph__viewport--desktop [data-work-package-id="slice-jump"]');
    await target.waitFor();
    expect(await target.getAttribute("data-attention-jump")).toBe("true");
    expect(await page.locator('.execution-graph__viewport--desktop [data-group-id="group-jump"]').getAttribute("data-expanded")).toBe("true");

    await page.close();
  }, 20_000);

  it("opens the stable repository hierarchy when jumping to nested attention", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    await disableFocusBoard(page);
    page.setDefaultTimeout(5_000);
    await page.route("**/api/v1/sympp/operator/config*", (route) =>
      route.fulfill({ json: { apiBase: "/api/v1/sympp/operator", basePath: "/sympp/board" } }),
    );
    await page.route("**/api/v1/sympp/operator/dashboard/events", (route) => route.abort());
    await page.route("**/api/v1/sympp/operator/dashboard", (route) => route.fulfill({ json: attentionDashboard }));
    await page.route("**/api/v1/sympp/operator/work-packages/wp-jump", (route) => route.fulfill({
      json: { work_package: attentionPackage, blockers: [attentionBlocker] },
    }));
    await page.route("**/api/v1/sympp/operator/work-requests/wr-jump*", (route) => route.fulfill({
      json: attentionDashboard.work_request_details[0],
    }));

    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
    await page.waitForTimeout(500);
    await page.keyboard.press("Escape");
    await page.locator(".dialog-overlay").waitFor({ state: "hidden" });
    await page.getByRole("button", { name: "Active Blockers: 1" }).click();
    const panel = page.locator(".top-panel-inline");
    await panel.getByRole("button", { name: /Open Blocked/ }).click();
    const modal = page.locator(".attention-dialog");
    await modal.getByTitle("Jump to Jump package").click();

    const request = page.locator('.workstream-repo-card [data-request-id="wr-jump"]');
    const group = request.locator('[data-group-id="group-jump"]');
    const target = group.locator('[data-work-package-id="slice-jump"]');
    await target.waitFor({ state: "visible" });
    await page.waitForFunction(() => document.querySelector('[data-work-package-id="slice-jump"]')?.getAttribute("data-attention-jump") === "true");
    expect(await request.getAttribute("data-expanded")).toBe("true");
    expect(await group.locator(":scope > .v3-product-node-header .v3-product-node-chevron-button").getAttribute("aria-expanded")).toBe("true");
    expect(await page.locator(".focus-board").count()).toBe(0);
    await page.setViewportSize({ width: 700, height: 800 });
    expect(await target.evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(" ").length)).toBe(2);
    expect(await target.locator(":scope > .v3-row-badge-slot").evaluate((element) => getComputedStyle(element).gridColumnStart)).toBe("2");

    await page.close();
  }, 20_000);
});

async function enableFocusBoard(page: Awaited<ReturnType<Browser["newPage"]>>) {
  await page.addInitScript((key) => localStorage.setItem(key, JSON.stringify({ useFocusBoard: true })), DASHBOARD_UI_STATE_KEY);
}

async function disableFocusBoard(page: Awaited<ReturnType<Browser["newPage"]>>) {
  await page.addInitScript((key) => localStorage.setItem(key, JSON.stringify({ useFocusBoard: false })), DASHBOARD_UI_STATE_KEY);
}

function browserExecutablePath() {
  const bundled = chromium.executablePath();
  if (existsSync(bundled)) return bundled;
  return browserCandidates().find(existsSync);
}

function browserCandidates() {
  if (os.platform() === "win32") {
    return [
      "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
      "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
      "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
      "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    ];
  }
  if (os.platform() === "darwin") {
    return ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"];
  }
  return ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser"];
}

const request = {
  id: "wr-interaction",
  title: "Interaction request",
  repo: "fixture/repo",
  repo_key: "fixture/repo",
  base_branch: "main",
  status: "sliced",
  work_package_count: 1,
};

const earlierLaneRequest = {
  id: "wr-earlier-lane",
  title: "Earlier lane request",
  repo: "fixture/secondary",
  repo_key: "fixture/secondary",
  base_branch: "main",
  status: "clarifying",
  open_question_count: 1,
  work_package_count: 0,
};

const followingGroupRequest = {
  id: "wr-following-group",
  title: "Following group request",
  repo: "fixture/secondary",
  repo_key: "fixture/secondary",
  base_branch: "main",
  status: "sliced",
  work_package_count: 1,
};

const priorityDashboard = {
  generated_at: "2026-07-23T12:00:00Z",
  work_requests: { work_requests: [request, earlierLaneRequest, followingGroupRequest], total_count: 3 },
  deferred: { dashboard_sections: true },
};

const deferredDashboard = {
  generated_at: "2026-07-23T12:00:00Z",
  work_packages: [{ id: "wp-interaction", status: "active" }, { id: "wp-following-group", status: "active" }],
  work_request_details: [{
    work_request: request,
    work_packages: [{
      id: "slice-interaction",
      work_request_id: request.id,
      work_package_id: "wp-interaction",
      title: "Interaction slice",
      status: "implementing",
      worker_signal: { status: "active" },
      pr_signal: { number: 42, url: "https://example.test/pull/42" },
    }],
    product_tree: {
      nodes: [{ id: "delivery", position: 0, title: "Delivery", work_package_ids: ["slice-interaction"] }],
      execution_graph: { available: true, work_package_ids: ["slice-interaction"], effective_edges: [], topological_order: ["slice-interaction"] },
    },
  }, {
    work_request: earlierLaneRequest,
    work_packages: [],
    clarification_questions: [{ id: "question-earlier-lane", status: "open" }],
    product_tree: { nodes: [] },
  }, {
    work_request: followingGroupRequest,
    work_packages: [{
      id: "slice-following-group",
      work_request_id: followingGroupRequest.id,
      work_package_id: "wp-following-group",
      title: "Following group slice",
      status: "implementing",
      worker_signal: { status: "active" },
    }],
    product_tree: {
      nodes: [{ id: "following", position: 0, title: "Following", work_package_ids: ["slice-following-group"] }],
      execution_graph: { available: true, work_package_ids: ["slice-following-group"], effective_edges: [], topological_order: ["slice-following-group"] },
    },
  }],
  active_blocking_edges: [],
  guidance_requests: { guidance_requests: [], total_count: 0 },
  solo_sessions: { solo_sessions: [], total_count: 0 },
  deferred: { dashboard_sections: false },
};

const attentionBlocker = {
  id: "blocker-jump",
  active: true,
  summary: "Needs approval before release",
  updated_at: "2026-07-30T09:15:00Z",
};

const attentionPackage = {
  id: "wp-jump",
  title: "Jump package",
  repo: "fixture/repo",
  status: "blocked",
  active_blocker_count: 1,
  active_blockers: [attentionBlocker],
};

const attentionRequest = {
  id: "wr-jump",
  title: "Jump request",
  repo: "fixture/repo",
  repo_key: "fixture/repo",
  base_branch: "main",
  status: "sliced",
  work_package_count: 1,
};

const attentionSlice = {
  id: "slice-jump",
  work_request_id: attentionRequest.id,
  work_package_id: attentionPackage.id,
  product_tree_node_id: "group-jump",
  title: "Jump package",
  status: "blocked",
  operational_state: { key: "blocked", label: "Blocked", tone: "danger" },
};

const attentionEdge = {
  id: "edge-jump",
  blocker_id: attentionBlocker.id,
  work_request_id: attentionRequest.id,
  work_package_id: attentionPackage.id,
  from: { kind: "work_package", id: "wp-source" },
  to: { kind: "work_package", id: attentionPackage.id },
  summary: attentionBlocker.summary,
  updated_at: attentionBlocker.updated_at,
};

const attentionDashboard = {
  generated_at: "2026-07-30T12:15:00Z",
  work_requests: { work_requests: [attentionRequest], total_count: 1 },
  work_packages: [attentionPackage],
  work_request_details: [{
    work_request: attentionRequest,
    work_packages: [attentionSlice],
    product_tree: {
      available: true,
      nodes: [{ id: "group-jump", position: 0, title: "Jump group", work_package_ids: [attentionSlice.id] }],
      execution_graph: { available: true, work_package_ids: [attentionSlice.id], effective_edges: [], topological_order: [attentionSlice.id] },
    },
  }],
  active_blocking_edges: [attentionEdge],
  guidance_requests: { guidance_requests: [], total_count: 0 },
  solo_sessions: { solo_sessions: [], total_count: 0 },
  deferred: { dashboard_sections: false },
};
