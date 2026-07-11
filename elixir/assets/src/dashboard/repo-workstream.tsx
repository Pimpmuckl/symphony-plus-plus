import type { ActiveBlockingEdge, CopyArchitectHandoff, GuidanceItem, WorkRequestDetail } from "@/types/dashboard";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { AlertTriangle, ChevronRight, GitBranch, GitPullRequest, Layers3, MessageSquareText, Split } from "lucide-react";
import { Collapsible, CollapsibleContent } from "@/components/ui/collapsible";
import { cn } from "@/lib/utils";
import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";
import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { CardDetailSelect, DashboardUpdateAnimations, REPO_WORKSTREAM_MOTION_MS } from "./runtime";
import { EMPTY_WORK_REQUEST_DETAILS, WorkstreamCategoryCounts } from "./dashboard-state";
import { RepoSummary } from "./dashboard-data";
import { RepoSummaryPlate } from "./dashboard-settings";
import { WorkstreamBoard } from "./workstream-board";
import { defaultRepoWorkstreamOpen, readStoredFinishedRequestChildren, readStoredRepoWorkstreamOpen, repoWorkstreamStateKey, writeStoredFinishedRequestChildren, writeStoredRepoWorkstreamOpen } from "./dashboard-persistence";
import { finishedRequestChildrenStorageKey, workstreamCategoryCounts } from "./workstream-data";
import { repoSummaryMetrics, type RepoSummaryMetricKey } from "./repo-summary-state";

export function RepoWorkstream({
  repo,
  requestDetailsByRepo,
  activeBlockingEdges,
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  canMutateOperatorActions,
  showWorkstreamContextBar,
  updateAnimations,
}: {
  repo: RepoSummary;
  requestDetailsByRepo: Map<string, WorkRequestDetail[]>;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  canMutateOperatorActions: boolean;
  showWorkstreamContextBar: boolean;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const stateKey = repoWorkstreamStateKey(repo);
  const contentId = useId();
  const repoDetails = requestDetailsByRepo.get(repo.repoKey) ?? EMPTY_WORK_REQUEST_DETAILS;
  const [expandedFinishedRequests, setExpandedFinishedRequests] = useState(() => readStoredFinishedRequestChildren());
  const setFinishedRequestChildrenOpen = useCallback((workRequestId: string, open: boolean) => {
    setExpandedFinishedRequests(() => {
      const next = { ...readStoredFinishedRequestChildren(), [finishedRequestChildrenStorageKey(stateKey, workRequestId)]: open };
      writeStoredFinishedRequestChildren(next);
      return next;
    });
  }, [stateKey]);
  const categoryCounts = useMemo(() => workstreamCategoryCounts(repoDetails), [repoDetails]);
  const [open, setOpen] = useState(() => readStoredRepoWorkstreamOpen(stateKey, defaultRepoWorkstreamOpen(repo)));
  const [openMotion, setOpenMotion] = useState(false);
  const previousOpenRef = useRef(open);
  const openMotionTimerRef = useRef<number | null>(null);
  const toggleOpen = useCallback(() => {
    setOpen((currentOpen) => !currentOpen);
  }, []);

  useEffect(
    () => () => {
      if (openMotionTimerRef.current !== null) {
        window.clearTimeout(openMotionTimerRef.current);
      }
    },
    [],
  );

  useLayoutEffect(() => {
    if (dashboardPrefersReducedMotion()) {
      previousOpenRef.current = open;
      return;
    }

    if (open && !previousOpenRef.current) {
      if (openMotionTimerRef.current !== null) {
        window.clearTimeout(openMotionTimerRef.current);
      }
      setOpenMotion(true);
      openMotionTimerRef.current = window.setTimeout(() => {
        setOpenMotion(false);
        openMotionTimerRef.current = null;
      }, REPO_WORKSTREAM_MOTION_MS + 120);
    }
    previousOpenRef.current = open;
  }, [open]);

  useEffect(() => {
    writeStoredRepoWorkstreamOpen(stateKey, open);
  }, [open, stateKey]);

  return (
    <Collapsible open={open} onOpenChange={setOpen}>
      <Card
        className="dashboard-glass-surface workstream-repo-card motion-card"
        data-open={open ? "true" : "false"}
      >
        <CardHeader className="dashboard-panel-header relative space-y-0 overflow-hidden border-b">
          <button
            type="button"
            className="absolute inset-0 cursor-pointer transition-colors hover:bg-muted/25 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
            aria-label={`${open ? "Collapse" : "Open"} ${repo.repo}`}
            aria-expanded={open}
            aria-controls={contentId}
            title={repo.repoRemote || undefined}
            onClick={toggleOpen}
          />
          <div className="v3-repo-header-grid pointer-events-none relative select-none">
            <div className="v3-repo-main">
              <span className="v3-repo-chevron-slot">
                <ChevronRight className={cn("size-4 transition-transform duration-200", open && "rotate-90")} />
              </span>
              <div className="v3-repo-title-group">
                <CardTitle className="v3-repo-title">
                  <GitBranch className="size-4 text-primary" />
                  <span className="truncate" title={repo.repoRemote || undefined}>{repo.repo}</span>
                </CardTitle>
                <p className="v3-repo-meta">{repo.baseBranches.join(", ") || "main"}</p>
              </div>
            </div>
            <RepoSummaryStrip repo={repo} categoryCounts={categoryCounts} />
          </div>
        </CardHeader>
        <CollapsibleContent
          id={contentId}
          className="collapsible-content workstream-repo-content"
          data-board-open-motion={openMotion ? "open" : "idle"}
        >
          <CardContent className="p-3 sm:p-4" data-board-open-motion={openMotion ? "open" : "idle"}>
            <WorkstreamBoard
              repoLabel={repo.repo}
              repoDetails={repoDetails}
              packages={repo.packages}
              activeBlockingEdges={activeBlockingEdges}
              guidanceItems={guidanceItems}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              onCopyArchitectHandoff={onCopyArchitectHandoff}
              canMutateOperatorActions={canMutateOperatorActions}
              expandedFinishedRequests={expandedFinishedRequests}
              finishedRequestScopeKey={stateKey}
              onSetFinishedRequestChildrenOpen={setFinishedRequestChildrenOpen}
              showContextBar={showWorkstreamContextBar}
              updateAnimations={updateAnimations}
            />
          </CardContent>
        </CollapsibleContent>
      </Card>
    </Collapsible>
  );
}

export function RepoSummaryStrip({ repo, categoryCounts }: { repo: RepoSummary; categoryCounts: WorkstreamCategoryCounts }) {
  const metrics = repoSummaryMetrics(repo, categoryCounts);
  const progress = metrics.filter((item) => item.group === "progress" && (item.key !== "planNodes" || item.value > 0));
  const attention = metrics.filter((item) => item.group === "attention" && item.value > 0);

  return (
    <div className="v3-repo-summary-strip">
      <div className="v3-repo-summary-group" data-kind="progress">
        {progress.map((item) => (
          <RepoSummaryPlate
            key={item.key}
            className="v3-repo-summary-plate"
            icon={repoSummaryIcon(item.key)}
            label={item.label}
            summaryKey={item.key}
            value={item.value}
            tone={item.tone}
          />
        ))}
      </div>
      {attention.length > 0 ? <div className="v3-repo-summary-divider" /> : null}
      {attention.length > 0 ? (
        <div className="v3-repo-summary-group" data-kind="attention">
          {attention.map((item) => (
            <RepoSummaryPlate
              key={item.key}
              className="v3-repo-summary-plate"
              icon={repoSummaryIcon(item.key)}
              label={item.label}
              summaryKey={item.key}
              value={item.value}
              tone={item.tone}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}

function repoSummaryIcon(key: RepoSummaryMetricKey) {
  switch (key) {
    case "requests":
      return <GitPullRequest className="size-3.5" />;
    case "planNodes":
      return <Layers3 className="size-3.5" />;
    case "slices":
      return <Split className="size-3.5" />;
    case "guidance":
      return <MessageSquareText className="size-3.5" />;
    case "blockers":
      return <AlertTriangle className="size-3.5" />;
  }
}
