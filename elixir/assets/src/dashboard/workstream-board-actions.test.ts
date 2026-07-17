import { describe, expect, it } from "vitest";

import type { ActiveBlockingEdge, GuidanceItem, WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { CardDetailSelection } from "./runtime";
import { openBlockersForRequest, openBlockersForSlices, openGuidanceForSlice } from "./workstream-board-actions";

describe("workstream board action routing", () => {
  it("keeps slice guidance clicks scoped to the slice when only request guidance exists", () => {
    const selections: CardDetailSelection[] = [];
    const guidance: GuidanceItem[] = [requestGuidance("wr-1")];
    const detail = requestDetail("wr-1");
    const slice = plannedSlice("slice-1", "pkg-1");

    openGuidanceForSlice(detail, slice, undefined, guidance, () => {
      throw new Error("request guidance should not handle a slice chip");
    }, (selection) => selections.push(selection));

    expect(selections).toEqual([{ kind: "slice", detail, slice, pkg: undefined }]);
  });

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

  it("keeps slice blocker clicks scoped to the selected slice package", () => {
    const selections: CardDetailSelection[] = [];
    const detail = requestDetail("wr-1");
    const sliceTwo = plannedSlice("slice-2", "pkg-2");
    const pkgOne: WorkPackageCard = { id: "pkg-1", status: "blocked" };
    const pkgTwo: WorkPackageCard = {
      id: "pkg-2",
      status: "blocked",
      active_blocker_count: 1,
      active_blockers: [{ id: "blocker-2", active: true, summary: "Second slice blocker" }],
    };
    const requestWideEdgeForSliceOne: ActiveBlockingEdge = {
      id: "edge-1",
      blocker_id: "blocker-1",
      from: { kind: "work_package", id: "pkg-1" },
      to: { kind: "work_package", id: "pkg-other" },
      work_package_id: "pkg-1",
      work_request_id: "wr-1",
    };

    openBlockersForSlices(
      detail,
      [sliceTwo],
      new Map([
        ["pkg-1", pkgOne],
        ["pkg-2", pkgTwo],
      ]),
      new Map([["slice-2", 1]]),
      [requestWideEdgeForSliceOne],
      (selection) => selections.push(selection),
    );

    expect(selections).toEqual([
      {
        kind: "blocker",
        blocker: expect.objectContaining({
          blocker_id: "blocker-2",
          work_package_id: "pkg-2",
        }),
        pkg: pkgTwo,
        detail,
        slice: sliceTwo,
      },
    ]);
    expect(selections[0]?.kind === "blocker" ? selections[0].blocker : null).not.toBe(requestWideEdgeForSliceOne);
  });

  it("does not route blocker source slice clicks to the blocked target edge", () => {
    const selections: CardDetailSelection[] = [];
    const detail = requestDetail("wr-1");
    const sourceSlice = plannedSlice("slice-source", "pkg-source");
    const blockedSlice = plannedSlice("slice-blocked", "pkg-blocked");
    const edge: ActiveBlockingEdge = {
      id: "edge-blocked",
      blocker_id: "blocker-blocked",
      from: { kind: "work_package", id: sourceSlice.work_package_id! },
      to: { kind: "work_package", id: blockedSlice.work_package_id! },
      work_package_id: blockedSlice.work_package_id,
      work_request_id: "wr-1",
    };

    openBlockersForSlices(
      detail,
      [sourceSlice],
      new Map(),
      new Map(),
      [edge],
      (selection) => selections.push(selection),
    );

    expect(selections).toEqual([{ kind: "request", detail }]);
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

  it("does not invent a slice blocker target when node summary blockers lack slice evidence", () => {
    const selections: CardDetailSelection[] = [];
    const detail = requestDetail("wr-1");
    const slice = plannedSlice("slice-1", "pkg-1");

    openBlockersForSlices(detail, [slice], new Map(), new Map(), [], (selection) => selections.push(selection));

    expect(selections).toEqual([{ kind: "request", detail }]);
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

function requestGuidance(workRequestId: string): GuidanceItem {
  return {
    source: "clarification",
    id: "question-1",
    repo: "symphony-plus-plus",
    repoKey: "symphony-plus-plus",
    title: "Request clarification",
    workRequestId,
    detail: "Request-level question",
    question: {
      id: "question-1",
      question: "Clarify request",
      status: "open",
      work_request_id: workRequestId,
    },
    request: { id: workRequestId },
  };
}
