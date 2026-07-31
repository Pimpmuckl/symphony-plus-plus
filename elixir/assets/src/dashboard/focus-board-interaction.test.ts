import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import { chromium, type Browser } from "playwright";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type ViteDevServer } from "vite";

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
  it("hydrates priority and deferred data before exercising focus choreography", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
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
      route.fulfill({ json: { apiBase: "/api/v1/sympp/operator", basePath: "/sympp/board", operatorMode: true } }),
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
    await board.getByText("Interaction request", { exact: true }).waitFor({ state: "attached" });
    await deferredRequested;
    expect(requests).toEqual(["priority", "deferred"]);

    releaseDeferred();
    const row = board.locator('[data-request-id="wr-interaction"]');
    const activity = row.locator('[data-frontier-measure="state"]');
    await activity.waitFor({ state: "attached" });
    const section = activity.locator("xpath=ancestor::section[contains(@class,'focus-board__section')][1]");
    if (await section.getAttribute("data-section-open") !== "true") await section.locator(".focus-board__section-toggle").click();
    await row.waitFor();
    const expand = row.locator(".v3-request-chevron-button");

    const widthBefore = await board.evaluate((element) => element.style.getPropertyValue("--focus-frontier-state-width"));
    await activity.evaluate((element) => {
      element.textContent = "A deliberately much longer measured activity label";
    });
    await page.setViewportSize({ width: 1100, height: 800 });
    await page.waitForFunction(
      (previous) => document.querySelector<HTMLElement>(".focus-board")?.style.getPropertyValue("--focus-frontier-state-width") !== previous,
      widthBefore,
    );

    await page.keyboard.press("Escape");
    await page.locator(".dialog-overlay").waitFor({ state: "hidden" });
    await expand.click();
    await waitForPhase(page, "focused");
    expect(await board.getAttribute("data-focus-request-id")).toBe("wr-interaction");
    const visibleMatchingGroup = board.locator('[data-focus-lane="attention"] [data-focus-repo-key="fixture/secondary"]');
    expect(await visibleMatchingGroup.getAttribute("aria-hidden")).toBeNull();
    expect(await visibleMatchingGroup.evaluate((element) => (element as HTMLElement).inert)).toBe(false);
    await board.getByRole("button", { name: "Collapse Interaction request" }).click();
    await waitForCollapsed(page);

    await page.emulateMedia({ reducedMotion: "reduce" });
    await board.evaluate((element) => {
      const phases: string[] = [];
      new MutationObserver(() => phases.push(element.getAttribute("data-focus-phase") ?? "collapsed"))
        .observe(element, { attributeFilter: ["data-focus-phase"] });
      Object.assign(element, { testFocusPhases: phases });
    });
    await expand.click();
    await waitForPhase(page, "focused");
    const reducedMotionPhases = await board.evaluate((element) =>
      (element as HTMLElement & { testFocusPhases: string[] }).testFocusPhases,
    );
    expect(reducedMotionPhases).not.toContain("spacing");
    expect(reducedMotionPhases).not.toContain("grouping");
    expect(reducedMotionPhases).not.toContain("expanding");
    await page.keyboard.press("Escape");
    await waitForCollapsed(page);

    await page.close();
  }, 20_000);

  it("expands note-only requests in place and pushes following content down", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    page.setDefaultTimeout(5_000);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.route("**/api/v1/sympp/operator/config*", (route) =>
      route.fulfill({ json: { apiBase: "/api/v1/sympp/operator", basePath: "/sympp/board", operatorMode: true } }),
    );
    await page.route("**/api/v1/sympp/operator/dashboard/events", (route) => route.abort());
    await page.route("**/api/v1/sympp/operator/dashboard", (route) => route.fulfill({ json: inlinePriorityDashboard }));
    await page.route("**/api/v1/sympp/operator/dashboard/deferred", (route) => route.fulfill({ json: inlineDeferredDashboard }));

    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
    const board = page.locator(".focus-board");
    const nextSection = board.locator('[data-focus-lane="next"]');
    await nextSection.getByText("Inline note request", { exact: true }).waitFor({ state: "attached" });
    await page.keyboard.press("Escape");
    await page.locator(".dialog-overlay").waitFor({ state: "hidden" });
    await nextSection.locator(".focus-board__section-toggle").click();
    await nextSection.getByText("Inline note request", { exact: true }).waitFor();

    const row = nextSection.locator('[data-request-id="wr-inline-note"]');
    const waitingSection = board.locator('[data-focus-lane="waiting"]');
    const waitingTopBefore = (await waitingSection.boundingBox())!.y;
    await row.locator(".v3-request-chevron-button").click();
    const waitingTopAfter = (await waitingSection.boundingBox())!.y;

    expect(await row.getAttribute("data-expanded")).toBe("true");
    expect(await row.getByText("No work has been created yet.", { exact: false }).isVisible()).toBe(true);
    expect(await board.getAttribute("data-focus-phase")).toBeNull();
    expect(await board.locator(".focus-board__expanded-slot").count()).toBe(0);
    expect(waitingTopAfter).toBeGreaterThan(waitingTopBefore + 20);

    await page.close();
  }, 20_000);

  it("closes the blocker overview and modal when jumping to its WorkPackage", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    page.setDefaultTimeout(5_000);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.route("**/api/v1/sympp/operator/config*", (route) =>
      route.fulfill({ json: { apiBase: "/api/v1/sympp/operator", basePath: "/sympp/board", operatorMode: true } }),
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
    await waitForPhase(page, "focused");
    expect(await page.locator(".focus-board").getAttribute("data-focus-request-id")).toBe("wr-jump");
    const target = page.locator('.execution-graph__viewport--desktop [data-work-package-id="slice-jump"]');
    await target.waitFor();
    expect(await target.getAttribute("data-attention-jump")).toBe("true");
    expect(await page.locator('.execution-graph__viewport--desktop [data-group-id="group-jump"]').getAttribute("data-expanded")).toBe("true");

    await page.close();
  }, 20_000);
});

async function waitForPhase(page: Awaited<ReturnType<Browser["newPage"]>>, phase: string) {
  await page.waitForFunction(
    (expected) => document.querySelector(".focus-board")?.getAttribute("data-focus-phase") === expected,
    phase,
  );
}

async function waitForCollapsed(page: Awaited<ReturnType<Browser["newPage"]>>) {
  await page.waitForFunction(() => !document.querySelector(".focus-board")?.hasAttribute("data-focus-request-id"));
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

const inlineNoteRequest = {
  id: "wr-inline-note",
  title: "Inline note request",
  repo: "fixture/repo",
  repo_key: "fixture/repo",
  base_branch: "main",
  status: "clarifying",
  work_package_count: 0,
};

const inlineWaitingRequest = {
  id: "wr-inline-waiting",
  title: "Waiting request",
  repo: "fixture/repo",
  repo_key: "fixture/repo",
  base_branch: "main",
  status: "sliced",
  work_package_count: 1,
};

const inlinePriorityDashboard = {
  generated_at: "2026-07-30T12:15:00Z",
  work_requests: { work_requests: [inlineNoteRequest, inlineWaitingRequest], total_count: 2 },
  deferred: { dashboard_sections: true },
};

const inlineDeferredDashboard = {
  generated_at: "2026-07-30T12:15:00Z",
  work_packages: [],
  work_request_details: [{
    work_request: inlineNoteRequest,
    work_packages: [],
    product_tree: { nodes: [] },
  }, {
    work_request: inlineWaitingRequest,
    work_packages: [{
      id: "slice-inline-waiting",
      work_request_id: inlineWaitingRequest.id,
      title: "Waiting package",
      status: "blocked",
      dependency_signal: {
        satisfied: 0,
        required: 1,
        active: 0,
        blocked: 1,
        unmet_work_package_ids: ["upstream"],
        inputs: [],
      },
    }],
    product_tree: { nodes: [] },
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
