import { useEffect, useRef, type RefObject } from "react";

import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";
import type { WorkRequestDetail } from "@/types/dashboard";
import { REPO_WORKSTREAM_MOTION_MS } from "./runtime";
import type { AttentionJumpTarget } from "./workstream-attention";

export function useRepositoryAttentionJump(
  boardRef: RefObject<HTMLDivElement | null>,
  jumpTarget: AttentionJumpTarget | null | undefined,
  repoDetails: WorkRequestDetail[],
  openRequest: (workRequestId: string, open: boolean) => void,
) {
  const handledTokenRef = useRef(0);

  useEffect(() => {
    if (!jumpTarget || handledTokenRef.current >= jumpTarget.token || !repoDetails.some((detail) => detail.work_request.id === jumpTarget.requestId)) return;
    const root = boardRef.current;
    if (!root) return;

    openRequest(jumpTarget.requestId, true);
    let settleTimer: number | null = null;
    const revealTarget = () => {
      const row = root.querySelector<HTMLElement>(`[data-request-id="${CSS.escape(jumpTarget.requestId)}"]`);
      if (!row || row.dataset.expanded !== "true") return;
      let target = row;

      for (const groupId of jumpTarget.groupIds) {
        const group = row.querySelector<HTMLElement>(`[data-group-id="${CSS.escape(groupId)}"]`);
        if (!group) return;
        const toggle = group.querySelector<HTMLButtonElement>(":scope > .v3-product-node-header .v3-product-node-chevron-button");
        if (toggle?.getAttribute("aria-expanded") === "false") {
          toggle.click();
          return;
        }
        target = group;
      }

      if (jumpTarget.workPackageId) {
        const workPackage = row.querySelector<HTMLElement>(`[data-work-package-id="${CSS.escape(jumpTarget.workPackageId)}"]`);
        if (!workPackage) return;
        target = workPackage;
      }

      if (settleTimer !== null) return;
      observer.disconnect();
      settleTimer = window.setTimeout(() => {
        handledTokenRef.current = jumpTarget.token;
        target.dataset.attentionJump = "true";
        target.scrollIntoView({ block: "center", inline: "nearest", behavior: dashboardPrefersReducedMotion() ? "auto" : "smooth" });
        window.setTimeout(() => delete target.dataset.attentionJump, 1_800);
      }, REPO_WORKSTREAM_MOTION_MS);
    };
    const observer = new MutationObserver(revealTarget);
    observer.observe(root, { attributes: true, childList: true, subtree: true });
    const frame = window.requestAnimationFrame(revealTarget);
    return () => {
      observer.disconnect();
      window.cancelAnimationFrame(frame);
      if (settleTimer !== null) window.clearTimeout(settleTimer);
    };
  }, [boardRef, jumpTarget, openRequest, repoDetails]);
}
