import { describe, expect, it } from "vitest";

import type { ActiveBlockingEdge, WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { CardDetailSelection } from "./runtime";
import { openBlockersForRequest } from "./workstream-board-actions";

describe("workstream board action routing", () => {
  it("routes request blocker clicks to a request-owned blocker package", () => {
    const selections: CardDetailSelection[] = [];
    const detail = requestDetail("wr-1");
    const slice = plannedSlice("slice-1", "pkg-1");
    const pkg: WorkPackageCard = { id: "pkg-1", status: "active" };
    const edge: ActiveBlockingEdge = {
      id: "edge-1",
      blocker_id: "blocker-1",
      from: { kind: "work_package", id: "pkg-1" },
      to: { kind: "work_package", id: "pkg-other" },
      work_package_id: "pkg-1",
      work_request_id: "wr-1",
    };

    openBlockersForRequest(detail, [slice], new Map([["pkg-1", pkg]]), new Map(), [edge], (selection) => selections.push(selection));

    expect(selections).toEqual([{ kind: "blocker", blocker: edge, pkg, detail, slice }]);
  });

  it("routes package-card blocker fallback clicks to the real blocker modal", () => {
    const selections: CardDetailSelection[] = [];
    const detail = requestDetail("wr-1");
    const slice = plannedSlice("slice-1", "pkg-1");
    const pkg: WorkPackageCard = {
      id: "pkg-1",
      status: "blocked",
      active_blocker_count: 1,
      active_blockers: [{ id: "blocker-1", active: true, summary: "Scope permission needed" }],
    };

    openBlockersForRequest(detail, [slice], new Map([["pkg-1", pkg]]), new Map([["slice-1", 1]]), [], (selection) => selections.push(selection));

    expect(selections).toEqual([
      {
        kind: "blocker",
        blocker: expect.objectContaining({
          blocker_id: "blocker-1",
          summary: "Scope permission needed",
          work_package_id: "pkg-1",
        }),
        pkg,
        detail,
        slice,
      },
    ]);
  });

});

function requestDetail(id: string): WorkRequestDetail {
  return {
    work_request: { id, title: id },
  };
}

function plannedSlice(id: string, workPackageId?: string): WorkRequestPackage {
  return {
    id,
    title: id,
    work_request_id: "wr-1",
    work_package_id: workPackageId,
  };
}
