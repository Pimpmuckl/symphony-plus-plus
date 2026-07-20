import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";

import { RequestHeaderActions } from "./workstream-row-ui";
import type { WorkRequestDetail } from "@/types/dashboard";

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
});
