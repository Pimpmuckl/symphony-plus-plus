import { describe, expect, it } from "vitest";

import type { WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";

import type { RepoSummary } from "./dashboard-data";
import { filterWorkstreamsBySearch, matchesDashboardSearch } from "./dashboard-search";

describe("dashboard search", () => {
  it("matches compact fuzzy dashboard text", () => {
    expect(matchesDashboardSearch("nsvkrk", ["nextide-saas-vod-kraken"])).toBe(true);
    expect(matchesDashboardSearch("wr 123", ["wr_123", "Creator roster read model"])).toBe(true);
    expect(matchesDashboardSearch("missing", ["Creator roster read model"])).toBe(false);
    expect(matchesDashboardSearch("zzzz", ["wr_zabzcydzef"])).toBe(false);
    expect(matchesDashboardSearch("replay", ["ready plan analysis yearly"])).toBe(false);
  });

  it("keeps repo matches scoped to the repo shell and trims to matching request/package content otherwise", () => {
    const pkg: WorkPackageCard = { id: "wp_backend", title: "Backend API", repo: "vod-api" };
    const detail: WorkRequestDetail = {
      work_request: { id: "wr_creator_roster", title: "Creator roster read model", repo: "vod-api" },
      work_packages: [{ id: "wrs_backend", work_request_id: "wr_creator_roster", title: "Fast creator read", work_package_id: pkg.id }],
    };
    const repo: RepoSummary = {
      repoKey: "vod-api",
      repo: "nextide-saas-vod-api",
      baseBranches: ["main"],
      requested: 1,
      active: 1,
      implementing: 0,
      finished: 0,
      guidanceCount: 0,
      blockerCount: 0,
      packages: [pkg],
      requests: [detail.work_request],
    };

    const repoMatch = filterWorkstreamsBySearch([repo], new Map([[repo.repoKey, [detail]]]), "vod api");
    const requestMatch = filterWorkstreamsBySearch([repo], new Map([[repo.repoKey, [detail]]]), "creator roster");
    const miss = filterWorkstreamsBySearch([repo], new Map([[repo.repoKey, [detail]]]), "billing");

    expect(repoMatch.repos[0]).toMatchObject({ repo: repo.repo, packages: [], requests: [] });
    expect(repoMatch.requestDetailsByRepo.get(repo.repoKey)).toEqual([]);
    expect(requestMatch.repos[0].packages).toEqual([pkg]);
    expect(requestMatch.requestDetailsByRepo.get(repo.repoKey)).toEqual([detail]);
    expect(miss.repos).toEqual([]);
  });
});
