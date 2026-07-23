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
});

describe("focus board interactions", () => {
  it("hydrates priority and deferred data before exercising focus choreography", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    page.setDefaultTimeout(3_000);
    let releaseDeferred!: () => void;
    const deferredReady = new Promise<void>((resolve) => {
      releaseDeferred = resolve;
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
      await deferredReady;
      await route.fulfill({ json: deferredDashboard });
    });

    await page.goto(url);
    const board = page.locator(".focus-board");
    await board.getByText("Interaction request", { exact: true }).waitFor({ state: "attached" });
    expect(requests).toEqual(["priority", "deferred"]);

    releaseDeferred();
    const activity = board.locator('[data-frontier-measure="state"]');
    await activity.waitFor({ state: "attached" });
    const row = activity.locator("xpath=ancestor::section[contains(@class,'v3-request-row')][1]");
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

const priorityDashboard = {
  generated_at: "2026-07-23T12:00:00Z",
  work_requests: { work_requests: [request], total_count: 1 },
  deferred: { dashboard_sections: true },
};

const deferredDashboard = {
  generated_at: "2026-07-23T12:00:00Z",
  work_packages: [{ id: "wp-interaction", status: "active" }],
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
    },
  }],
  active_blocking_edges: [],
  guidance_requests: { guidance_requests: [], total_count: 0 },
  solo_sessions: { solo_sessions: [], total_count: 0 },
  deferred: { dashboard_sections: false },
};
