import { describe, expect, it } from "vitest";

import { operationalBadgeVariant, operationalStatusIsRunning, sliceCardTone, sliceLane } from "./operational-state";
import type { WorkRequestPackage } from "@/types/dashboard";

describe("operational state presentation", () => {
  it("uses guidance color for clarifying statuses", () => {
    expect(operationalBadgeVariant({ key: "clarifying", label: "Clarifying", tone: "warning" }, "clarifying")).toBe("guidance");
    expect(operationalBadgeVariant(undefined, "human_info_needed")).toBe("guidance");
  });

  it("uses ready color for ready slices", () => {
    for (const status of ["approved", "ready_for_worker", "ready_to_finish", "sliced"]) {
      const slice = plannedSlice(status);

      expect(sliceCardTone(slice, undefined, sliceLane(slice))).toBe("ready");
      expect(operationalBadgeVariant(slice.operational_state, slice.status)).toBe("ready");
    }
  });

  it("keeps planned WorkPackages visually quiet", () => {
    const slice = plannedSlice("planned");

    expect(sliceCardTone(slice, undefined, sliceLane(slice))).toBe("muted");
    expect(operationalBadgeVariant(slice.operational_state, slice.status)).toBe("secondary");
  });

  it("animates running labels, not merely records with active runtime metadata", () => {
    expect(operationalStatusIsRunning({ key: "reviewing", label: "Reviewing" }, "reviewing")).toBe(true);
    expect(operationalStatusIsRunning({ key: "ready_for_merge", label: "Ready For Merge", has_active_worker: true }, "ready_for_merge")).toBe(false);
  });
});

function plannedSlice(status: string): WorkRequestPackage {
  return {
    id: `slice-${status}`,
    work_request_id: "wr-colors",
    status,
    operational_state: { key: status, label: "Ready" },
  };
}
