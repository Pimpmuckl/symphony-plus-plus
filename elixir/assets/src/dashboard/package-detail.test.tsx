import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";

import { Dialog } from "@/components/ui/dialog";
import { BlockerDetailContent, SliceDetailContent, blockerDetailWorkPackageId, linkedPackageStateActions, scopedBlockerDetailPayload } from "./package-detail";
import type { CardDetailSelection } from "./runtime";
import type { WorkPackageDetailPayload, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import type { AttentionTarget } from "./workstream-attention";

describe("package detail blocker modal", () => {
  it("does not hydrate blocker detail from a different package with the same blocker id", () => {
    const selection: Extract<CardDetailSelection, { kind: "blocker" }> = {
      kind: "blocker",
      pkg: { id: "pkg-selected", title: "Selected package", status: "blocked" },
      blocker: {
        id: "edge-selected",
        blocker_id: "shared-blocker",
        from: { kind: "work_package", id: "pkg-source" },
        to: { kind: "work_package", id: "pkg-selected" },
        summary: "Selected blocker",
        body: "Selected body",
        work_package_id: "pkg-selected",
      },
    };
    const detailPayload: WorkPackageDetailPayload = {
      work_package: { id: "pkg-other", title: "Other package", status: "blocked" },
      blockers: [{ id: "shared-blocker", active: true, summary: "Stale blocker", body: "Stale body" }],
    };

    expect(scopedBlockerDetailPayload(selection, detailPayload)).toBeNull();
  });

  it("uses the blocked WorkPackage rather than the blocker source as the clear target", () => {
    const selection: Extract<CardDetailSelection, { kind: "blocker" }> = {
      kind: "blocker",
      blocker: {
        id: "edge-source-only",
        blocker_id: "shared-blocker",
        from: { kind: "work_package", id: "pkg-source" },
        to: { kind: "work_package", id: "pkg-blocked" },
        summary: "Selected blocker",
      },
    };

    expect(blockerDetailWorkPackageId(selection, null)).toBe("pkg-blocked");
  });

  it("hides blocker clearing outside local operator mode", () => {
    const selection: Extract<CardDetailSelection, { kind: "blocker" }> = {
      kind: "blocker",
      pkg: { id: "pkg-selected", title: "Selected package", status: "blocked" },
      blocker: {
        id: "edge-selected",
        blocker_id: "scope-blocker",
        from: { kind: "work_package", id: "pkg-source" },
        to: { kind: "work_package", id: "pkg-selected" },
        summary: "Selected blocker",
        body: "Selected body",
        work_package_id: "pkg-selected",
      },
    };
    const content = (canMutateOperatorActions: boolean) => (
      <Dialog open>
        <BlockerDetailContent
          selection={selection}
          detailPayload={null}
          loading={false}
          error={null}
          onClearWorkPackageBlocker={async () => undefined}
          canMutateOperatorActions={canMutateOperatorActions}
        />
      </Dialog>
    );

    const readOnlyMarkup = renderToStaticMarkup(content(false));
    const operatorMarkup = renderToStaticMarkup(content(true));

    expect(readOnlyMarkup).not.toContain(">Clear<");
    expect(operatorMarkup).toContain(">Clear<");
  });
});

describe("linked WorkPackage blocker summary", () => {
  it("opens status-only blocked packages without inventing an active blocker record", () => {
    const slice: WorkRequestPackage = {
      id: "slice-status-blocked",
      work_request_id: "wr-status-blocked",
      work_package_id: "wp-status-blocked",
      status: "blocked",
      title: "Status-only blocker",
    };
    const detail: WorkRequestDetail = {
      work_request: { id: "wr-status-blocked", title: "Blocked request" },
      work_packages: [slice],
    };
    const pkg = { id: "wp-status-blocked", status: "blocked", active_blocker_count: 0 };
    const attentionTarget: AttentionTarget = {
      items: [{
        kind: "status",
        key: "status:blocked:wp-status-blocked",
        label: "Blocked",
        tone: "blocked",
        title: "Status-only blocker",
        detail: "Raw lifecycle status is blocked.",
        selection: { kind: "slice", detail, slice, pkg },
      }],
    };

    const markup = renderToStaticMarkup(
      <Dialog open>
        <SliceDetailContent
          detail={detail}
          slice={slice}
          pkg={pkg}
          attentionTarget={attentionTarget}
          onSelectAttention={() => undefined}
          onSubmitComment={async () => ({ id: "comment" })}
          onResolveComment={async () => ({ id: "comment" })}
          canMutateComments={false}
        />
      </Dialog>,
    );

    expect(markup).toContain("<button");
    expect(markup).toContain("Package is marked blocked without a separate blocker record.");
    expect(markup).not.toContain("1 active blocker");
  });
});

describe("package detail state actions", () => {
  it("shows closeout only for ready linked packages without merge requirements", () => {
    expect(
      linkedPackageStateActions(
        { id: "pkg-ready-finish", status: "ready_for_merge", merge_required: false, pr_required: false },
        { key: "ready_to_finish", raw_status: "ready_for_merge", tone: "success", merge_required: false, pr_required: false },
        true,
        true,
      ),
    ).toEqual([{ value: "completed_no_pr", label: "Close With Evidence" }]);
  });

  it("does not expose closeout when ready-to-finish evidence is incomplete", () => {
    expect(
      linkedPackageStateActions(
        { id: "pkg-ready-finish-warning", status: "ready_for_merge", merge_required: false, pr_required: false },
        { key: "ready_to_finish", raw_status: "ready_for_merge", tone: "warning", merge_required: false, pr_required: false },
        true,
        true,
      ),
    ).toEqual([]);
  });

  it("keeps merge actions for ready linked packages that require merge", () => {
    expect(
      linkedPackageStateActions(
        { id: "pkg-ready-merge", status: "ready_for_merge", merge_required: true, pr_required: true },
        { key: "merge_ready", raw_status: "ready_for_merge", merge_required: true, pr_required: true },
        true,
        true,
      ),
    ).toEqual([
      { value: "merged", label: "Mark Merged" },
    ]);
  });

  it("keeps merge actions for architect-merge packages that do not require a human PR", () => {
    expect(
      linkedPackageStateActions(
        { id: "pkg-architect-merge", status: "ready_for_architect_merge", merge_required: true, pr_required: false },
        { key: "merge_ready", raw_status: "ready_for_architect_merge", merge_required: true, pr_required: false },
        true,
        true,
      ),
    ).toEqual([
      { value: "merged", label: "Mark Merged" },
    ]);
  });

  it("keeps merge actions for architect-merge fallback cards without operational state", () => {
    expect(
      linkedPackageStateActions(
        { id: "pkg-architect-merge-fallback", status: "ready_for_architect_merge", merge_required: true, pr_required: false },
        null,
        true,
        true,
      ),
    ).toEqual([
      { value: "merged", label: "Mark Merged" },
    ]);
  });

  it("does not expose closeout for non-merge packages before terminal readiness", () => {
    expect(
      linkedPackageStateActions(
        { id: "pkg-worker", status: "ready_for_worker", merge_required: false, pr_required: false },
        { key: "ready_for_worker", raw_status: "ready_for_worker", merge_required: false, pr_required: false },
        true,
        true,
      ),
    ).toEqual([]);
  });
});
