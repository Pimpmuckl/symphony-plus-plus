import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";

import { RequestHeaderActions } from "./workstream-row-ui";
import { ProductSliceRow } from "./workstream-slice-row";
import type { PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";

describe("workstream row actions", () => {
  it("hides architect handoff copying outside local operator mode", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-row-handoff",
        title: "Ready request",
        repo: "symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing",
      },
    };
    const content = (canMutateOperatorActions: boolean) => (
      <RequestHeaderActions
        detail={detail}
        progress={0}
        progressAttentionState={null}
        progressIconState="muted"
        progressLabel="Ready"
        onSelectCard={() => undefined}
        onCopyArchitectHandoff={async () => {
          throw new Error("not called during render");
        }}
        canMutateOperatorActions={canMutateOperatorActions}
      />
    );

    expect(renderToStaticMarkup(content(false))).not.toContain("Architect handoff");
    expect(renderToStaticMarkup(content(true))).toContain("Architect handoff");
  });

  it("shows child target context only when repo or base branch differs", () => {
    const detail: WorkRequestDetail = {
      work_request: { id: "wr-primary", title: "Primary", repo: "primary-repo", base_branch: "main" },
    };
    const sameRepoPackage: WorkPackageCard = { id: "pkg-local", repo: "primary-repo", base_branch: "main" };
    const branchOnlyPackage: WorkPackageCard = { id: "pkg-branch", repo: "primary-repo", base_branch: "release" };
    const crossRepoPackage: WorkPackageCard = { id: "pkg-cross", repo: "child-repo", base_branch: "release" };
    const sameRepoHtml = renderSlice(detail, { id: "slice-local", work_request_id: "wr-primary", title: "Local slice", target_base_branch: "main" }, sameRepoPackage);
    const branchOnlyHtml = renderSlice(detail, { id: "slice-branch", work_request_id: "wr-primary", title: "Branch slice", target_base_branch: "release" }, branchOnlyPackage);
    const crossRepoHtml = renderSlice(detail, { id: "slice-cross", work_request_id: "wr-primary", title: "Cross-repo slice", target_base_branch: "release" }, crossRepoPackage);

    expect(sameRepoHtml).not.toContain("v3-request-meta");
    expect(branchOnlyHtml).toContain("primary-repo");
    expect(branchOnlyHtml).toContain("release");
    expect(crossRepoHtml).toContain("child-repo");
    expect(crossRepoHtml).toContain("release");
  });
});

function renderSlice(detail: WorkRequestDetail, slice: PlannedSlice, pkg: WorkPackageCard) {
  return renderToStaticMarkup(
    <ProductSliceRow
      detail={detail}
      slice={slice}
      pkg={pkg}
      activeBlockerCountBySliceId={new Map()}
      activeBlockingEdges={[]}
      guidanceItems={[]}
      onSelectGuidance={() => undefined}
      onSelectCard={() => undefined}
      updateAnimations={{ motionFor: () => undefined }}
    />,
  );
}
