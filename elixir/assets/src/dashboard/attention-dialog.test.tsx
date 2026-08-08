import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { Dialog } from "@/components/ui/dialog";
import type { WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import { StatusAttentionBody } from "./attention-dialog";
import type { AttentionItem } from "./workstream-attention";

describe("status attention recovery", () => {
  it.each([
    ["package status", { status: "blocked" }, { status: "planned" }],
    ["projected package status", { status: "active" }, { status: "planned", work_package_status: "blocked" }],
    ["slice status", undefined, { status: "blocked" }],
  ])("shows Clear for a status-only blocker from %s", (_label, pkg, slice) => {
    const detail = requestDetail();
    const item: Extract<AttentionItem, { kind: "status" }> = {
      kind: "status",
      key: "status:blocked:wp-blocked",
      label: "Blocked",
      tone: "blocked",
      title: "Blocked package",
      detail: "No blocker record is attached.",
      selection: { kind: "slice", detail, slice: requestSlice(slice), pkg: pkg ? { id: "wp-blocked", ...pkg } : undefined },
    };

    expect(render(item)).toContain(">Clear<");
  });

  it("shows Clear for WorkRequest human-info attention without a question record", () => {
    const detail = requestDetail();
    detail.work_request.status = "human_info_needed";
    const item: Extract<AttentionItem, { kind: "status" }> = {
      kind: "status",
      key: "status:guidance:wr-attention",
      label: "Human Info Needed",
      tone: "guidance",
      title: "Human Info Needed",
      detail: "No question is attached.",
      selection: { kind: "request", detail },
    };

    expect(render(item)).toContain(">Clear<");
  });
});

function render(item: Extract<AttentionItem, { kind: "status" }>) {
  return renderToStaticMarkup(
    <Dialog open>
      <StatusAttentionBody
        item={item}
        location={{ repo: "fixture/repo", groups: [] }}
        onChangeWorkPackageState={async () => undefined}
        onChangeWorkRequestState={async () => undefined}
        onJumpToAttention={() => undefined}
      />
    </Dialog>,
  );
}

function requestDetail(): WorkRequestDetail {
  return { work_request: { id: "wr-attention", status: "sliced" }, work_packages: [] };
}

function requestSlice(overrides: Partial<WorkRequestPackage>): WorkRequestPackage {
  return { id: "slice-blocked", work_request_id: "wr-attention", work_package_id: "wp-blocked", status: "planned", ...overrides };
}
