import { describe, expect, it } from "vitest";

import type { GuidanceItem, SoloSession, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";

import type { BlockerItem } from "./dashboard-state";
import { updateDashboardAnimationBaseline } from "./update-animations";

const emptyInput = {
  blockerItems: [],
  guidanceItems: [],
  packages: [],
  requestDetails: [],
  soloSessions: [],
};

describe("dashboard update animation hydration", () => {
  it("baselines priority and deferred payloads together, then animates later changes", () => {
    const priority = updateDashboardAnimationBaseline(null, emptyInput, false);
    const hydratedPackage = { id: "wp-existing", status: "active", updated_at: "2026-07-23T10:00:00Z" } satisfies WorkPackageCard;
    const requestDetails = [{
      work_request: { id: "wr-existing", status: "sliced" },
      work_packages: [{ id: "slice-existing", work_request_id: "wr-existing", work_package_id: hydratedPackage.id, status: "implementing" }],
    }] satisfies WorkRequestDetail[];
    const guidanceItems = [{
      source: "guidance",
      id: "guidance-existing",
      repo: "fixture/repo",
      repoKey: "fixture/repo",
      title: "Existing guidance",
      packageId: hydratedPackage.id,
      detail: "Choose an option",
      guidance: { id: "guidance-existing", work_package_id: hydratedPackage.id, status: "open" },
    }] satisfies GuidanceItem[];
    const blockerItems = [{
      id: "blocker-existing",
      title: "Existing blocker",
      repo: "fixture/repo",
      status: "blocked",
      blockerCount: 1,
      detail: "Waiting",
      selection: { kind: "package", pkg: hydratedPackage },
    }] satisfies BlockerItem[];
    const soloSessions = [{ id: "solo-existing", status: "active" }] satisfies SoloSession[];
    const deferred = updateDashboardAnimationBaseline(priority.snapshot, {
      blockerItems,
      guidanceItems,
      packages: [hydratedPackage],
      requestDetails,
      soloSessions,
    }, true);

    expect(priority.motions).toEqual({});
    expect(deferred.motions).toEqual({});
    expect(deferred.snapshot).not.toBeNull();
    const baseline = deferred.snapshot!;
    expect([...baseline.keys()]).toEqual([
      "request:wr-existing",
      "slice:slice-existing",
      "package:wp-existing",
      "guidance:guidance:guidance-existing",
      "blocker:blocker-existing",
      "solo:solo-existing",
    ]);

    const liveUpdate = updateDashboardAnimationBaseline(baseline, {
      blockerItems,
      guidanceItems,
      packages: [{ ...hydratedPackage, updated_at: "2026-07-23T10:01:00Z" }],
      requestDetails,
      soloSessions,
    }, true);

    expect(liveUpdate.motions).toEqual({
      "slice:slice-existing": "changed",
      "package:wp-existing": "changed",
    });
  });
});
