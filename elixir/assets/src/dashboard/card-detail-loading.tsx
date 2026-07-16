import type { WorkRequestPackage, SoloSession, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { Badge } from "@/components/ui/badge";
import { DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Loader2 } from "lucide-react";
import type * as React from "react";
import { formatStatus } from "@/lib/status-labels";
import { operationalBadgeVariant, operationalLabel, sliceOperationalState } from "@/lib/operational-state";
import type { CardDetailSelection, CardDetailStage } from "./runtime";
import { repoDisplayName } from "./dashboard-persistence";
import { soloSessionStatusVariant } from "./solo-session-utils";

export function CardDetailLoadingContent({ selection, stage }: { selection: CardDetailSelection; stage: CardDetailStage }) {
  switch (selection.kind) {
    case "request":
      return <RequestDetailLoadingContent detail={selection.detail} stage={stage} />;
    case "slice":
      return <SliceDetailLoadingContent detail={selection.detail} slice={selection.slice} pkg={selection.pkg} stage={stage} />;
    case "package":
      return <PackageDetailLoadingContent selection={selection} stage={stage} />;
    case "blocker":
      return <BlockerDetailLoadingContent selection={selection} stage={stage} />;
    case "solo":
      return <SoloSessionDetailLoadingContent session={selection.session} stage={stage} />;
  }
}

function DetailLoadingHeader({ title, eyebrow, badge, stage }: { title: string; eyebrow: string; badge: React.ReactNode; stage: CardDetailStage }) {
  return (
    <DialogHeader className="detail-loading-header" data-guidance-section style={{ animationDelay: "35ms" }}>
      <div className="min-w-0">
        <DialogTitle className="detail-loading-title">{title}</DialogTitle>
        <DialogDescription className="detail-loading-eyebrow">{eyebrow}</DialogDescription>
      </div>
      <div className="detail-loading-actions">
        <output
          className="detail-loading-progress"
          data-progress-state={stage === "width" ? "exiting" : "active"}
          aria-label="Loading detail"
          aria-live="polite"
          aria-atomic="true"
        >
          <Loader2 className="size-3.5" aria-hidden="true" />
        </output>
        <div className="shrink-0">{badge}</div>
      </div>
    </DialogHeader>
  );
}

function RequestDetailLoadingContent({ detail, stage }: { detail: WorkRequestDetail; stage: CardDetailStage }) {
  const request = detail.work_request;
  const operational = request.operational_state || null;

  return (
    <DetailLoadingHeader
      title={request.title || request.id}
      eyebrow={`${repoDisplayName(request)} / ${request.base_branch || "main"} / ${request.work_type || "feature"}`}
      badge={<Badge variant={operationalBadgeVariant(operational, request.status)}>{operationalLabel(operational, request.status)}</Badge>}
      stage={stage}
    />
  );
}

function SliceDetailLoadingContent({
  detail,
  slice,
  pkg,
  stage,
}: {
  detail: WorkRequestDetail;
  slice: WorkRequestPackage;
  pkg?: WorkPackageCard;
  stage: CardDetailStage;
}) {
  const request = detail.work_request;
  const operational = sliceOperationalState(slice, pkg);

  return (
    <DetailLoadingHeader
      title={slice.title || slice.id}
      eyebrow={`${repoDisplayName(request)} / ${request.base_branch || "main"} / work package`}
      badge={<Badge variant={operationalBadgeVariant(operational, slice.status)}>{operationalLabel(operational, slice.status)}</Badge>}
      stage={stage}
    />
  );
}

function PackageDetailLoadingContent({ selection, stage }: { selection: Extract<CardDetailSelection, { kind: "package" }>; stage: CardDetailStage }) {
  const pkg = selection.pkg;
  const operational = pkg.operational_state || null;

  return (
    <DetailLoadingHeader
      title={pkg.title || pkg.id}
      eyebrow={`${repoDisplayName(pkg)} / ${pkg.base_branch || "main"} / ${pkg.kind || "work package"}`}
      badge={<Badge variant={operationalBadgeVariant(operational, pkg.status)}>{operationalLabel(operational, pkg.status)}</Badge>}
      stage={stage}
    />
  );
}

function BlockerDetailLoadingContent({ selection, stage }: { selection: Extract<CardDetailSelection, { kind: "blocker" }>; stage: CardDetailStage }) {
  const blocker = selection.blocker;
  const pkg = selection.pkg;

  return (
    <DetailLoadingHeader
      title={blocker.summary || pkg?.title || blocker.blocker_id || blocker.id}
      eyebrow={`${pkg ? repoDisplayName(pkg) : selection.detail ? repoDisplayName(selection.detail.work_request) : "Work package"} / active blocker`}
      badge={<Badge variant="danger">Blocked</Badge>}
      stage={stage}
    />
  );
}

function SoloSessionDetailLoadingContent({ session, stage }: { session: SoloSession; stage: CardDetailStage }) {
  return (
    <DetailLoadingHeader
      title={session.title || session.id}
      eyebrow={`${repoDisplayName(session)} / ${session.base_branch || "main"} / ${session.caller_id || "solo"}`}
      badge={<Badge variant={soloSessionStatusVariant(session.status)}>{formatStatus(session.status)}</Badge>}
      stage={stage}
    />
  );
}
