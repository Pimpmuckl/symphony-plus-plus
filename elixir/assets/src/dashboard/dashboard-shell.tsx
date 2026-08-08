import { AlertCircle, Loader2, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import type { CopyArchitectHandoff, DashboardPayload, GuidanceAnswerSubmission, GuidanceItem, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import { NewRequestDialog } from "@/components/dashboard/new-request-dialog";
import type { NewRequestForm } from "@/components/dashboard/new-request-dialog";
import type * as React from "react";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { TooltipProvider } from "@/components/ui/tooltip";
import { architectHandoffEligibleRequest } from "@/lib/operational-state";
import { AppDialogState } from "./dashboard-state";
import { ArchivedRequestsDialog, DashboardSettingsDialog, ThemeToggle } from "./dashboard-settings";
import { CardDetailSelection, DASHBOARD_LOGO_URL, DashboardConnectionIssue, DashboardTheme, DashboardUpdateAnimations, ResolveContextComment, SubmitContextComment, TopPanelKey, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, WorkspaceTab } from "./runtime";
import { DashboardDeferredDialogs } from "./dashboard-deferred-dialogs";
import { LiveLedgerBadge } from "./status-cards";
import { RepoSummary } from "./dashboard-data";
import { DashboardSearchControl } from "./dashboard-search-control";
import { DashboardWelcomeDialog } from "./dashboard-welcome";
import { AttentionBarControls } from "./attention-bar-controls";
import { StatusRail } from "./status-rail";
import { UpdateSimulationControls } from "./update-simulation-controls";
import { WorkspaceTabCarousel } from "./workspace-tabs";
import { readStoredTopPanel, writeDashboardUiStateValue } from "./dashboard-persistence";
import type { AttentionItem, AttentionJumpDestination, AttentionTarget } from "./workstream-attention";

type DashboardDisplayPreferences = {
  hideEmptyWorkstreams: boolean;
  showWorkstreamContextBar: boolean;
};

export function DashboardShell({
  archiveAfterDays,
  archivedRequestsLoading,
  archivedRequests,
  attentionItems,
  captureFailedMcpCalls,
  changeWorkPackageState,
  changeWorkRequestState,
  connectionIssue,
  copyArchitectHandoff,
  createWorkRequest,
  dashboard,
  dialogState,
  displayPreferences,
  dashboardSearchQuery,
  error,
  hiddenWorkstreamCount,
  linkedWorkPackageIds,
  loading,
  onArchiveWorkPackage,
  onArchiveWorkRequest,
  onOpenArchivedRequests,
  onClearWorkPackageBlocker,
  onCaptureFailedMcpCallsChange,
  onDeleteWorkRequest,
  onDashboardSearchQueryChange,
  onHideEmptyWorkstreamsChange,
  onJumpToAttention,
  onOpenDashboardOnBootChange,
  onRefreshDashboard,
  onResolveComment,
  onRestoreWorkRequest,
  onSelectAttention,
  onSelectCard,
  onSetNewRequestOpen,
  onShowWorkstreamContextBarChange,
  onShowWelcomeToastChange,
  onSubmitComment,
  onSubmitGuidanceAnswer,
  onUpdateArchiveAfterDays,
  onUpdateSoloSessionDeleteAfterDays,
  onWorkspaceTabChange,
  refreshing,
  requestDetails,
  repos,
  showUpdateSimulationControls,
  openDashboardOnBoot,
  showWelcomeToast,
  soloSessionDeleteAfterDays,
  surfaceRefreshVersion,
  theme,
  toggleTheme,
  updateAnimations,
  workspacePanes,
  workspaceTab,
}: {
  archiveAfterDays: number;
  archivedRequestsLoading: boolean;
  archivedRequests: WorkRequestCard[];
  attentionItems: AttentionItem[];
  captureFailedMcpCalls: boolean;
  changeWorkPackageState: WorkPackageStateMutation;
  changeWorkRequestState: WorkRequestStateMutation;
  connectionIssue: DashboardConnectionIssue | null;
  copyArchitectHandoff: CopyArchitectHandoff;
  createWorkRequest: (form: NewRequestForm) => Promise<WorkRequestDetail>;
  dashboard: DashboardPayload | null;
  dialogState: AppDialogState;
  displayPreferences: DashboardDisplayPreferences;
  dashboardSearchQuery: string;
  error: string | null;
  hiddenWorkstreamCount: number;
  linkedWorkPackageIds: Set<string>;
  loading: boolean;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  onArchiveWorkRequest: WorkRequestMutation;
  onOpenArchivedRequests: () => Promise<void>;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  onCaptureFailedMcpCallsChange: (capture: boolean) => Promise<void>;
  onDeleteWorkRequest: WorkRequestMutation;
  onDashboardSearchQueryChange: (query: string) => void;
  onHideEmptyWorkstreamsChange: (hide: boolean) => void;
  onJumpToAttention: (destination: AttentionJumpDestination) => void;
  onOpenDashboardOnBootChange: (open: boolean) => Promise<void>;
  onRefreshDashboard: () => Promise<void>;
  onResolveComment: ResolveContextComment;
  onRestoreWorkRequest: WorkRequestMutation;
  onSelectAttention: (target: AttentionTarget | null) => void;
  onSelectCard: (selection: CardDetailSelection | null) => void;
  onSetNewRequestOpen: (open: boolean) => void;
  onShowWorkstreamContextBarChange: (show: boolean) => void;
  onShowWelcomeToastChange: (show: boolean) => void;
  onSubmitComment: SubmitContextComment;
  onSubmitGuidanceAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
  onUpdateArchiveAfterDays: (archiveAfterDays: number) => Promise<void>;
  onUpdateSoloSessionDeleteAfterDays: (deleteAfterDays: number) => Promise<void>;
  onWorkspaceTabChange: (tab: WorkspaceTab) => void;
  refreshing: boolean;
  requestDetails: WorkRequestDetail[];
  repos: RepoSummary[];
  showUpdateSimulationControls: boolean;
  openDashboardOnBoot: boolean;
  showWelcomeToast: boolean;
  soloSessionDeleteAfterDays: number;
  surfaceRefreshVersion: number;
  theme: DashboardTheme;
  toggleTheme: () => void;
  updateAnimations: DashboardUpdateAnimations;
  workspacePanes: Record<WorkspaceTab, React.ReactNode>;
  workspaceTab: WorkspaceTab;
}) {
  const { hideEmptyWorkstreams, showWorkstreamContextBar } = displayPreferences;
  const dashboardAlertMessage = error;
  const guidanceCount = attentionItems.filter((item) => item.tone === "guidance").length;
  const blockerCount = attentionItems.filter((item) => item.tone === "blocked").length;
  const [visibleTopPanel, setOpenTopPanel] = useAutoClosingTopPanel(guidanceCount, blockerCount, dashboard !== null);
  const headerRef = useRef<HTMLElement | null>(null);
  const jumpToAttention = useCallback((destination: AttentionJumpDestination) => {
    setOpenTopPanel(null);
    onJumpToAttention(destination);
  }, [onJumpToAttention, setOpenTopPanel]);

  useDashboardScrollbarOffset(headerRef, loading);

  return (
    <TooltipProvider delayDuration={150}>
      <main className="dashboard-shell min-h-screen">
        <header ref={headerRef} className="dashboard-header-glass sticky top-0 z-20">
          <div className="mx-auto flex max-w-[1500px] flex-col gap-4 px-4 py-4 sm:px-6 lg:flex-row lg:items-center lg:justify-between lg:px-8">
            <div className="flex items-center gap-3">
              <div className="flex size-10 items-center justify-center overflow-hidden rounded-lg border bg-card shadow-sm motion-pop">
                <img src={DASHBOARD_LOGO_URL} alt="Symphony++" width={40} height={40} className="h-full w-full scale-[1.34] object-contain" />
              </div>
              <div>
                <h1 className="text-xl font-semibold">Symphony++</h1>
                <p className="text-sm text-muted-foreground">Operator cockpit</p>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              {showUpdateSimulationControls ? <UpdateSimulationControls /> : null}
              <LiveLedgerBadge error={error} connectionIssue={connectionIssue} databasePath={dashboard?.ledger?.database} />
              <DashboardSearchControl value={dashboardSearchQuery} onValueChange={onDashboardSearchQueryChange} />
              <AttentionBarControls
                attentionItems={attentionItems}
                openPanel={visibleTopPanel}
                onToggle={setOpenTopPanel}
              />
              <ThemeToggle theme={theme} onToggle={toggleTheme} />
              <DashboardSettingsDialog
                archiveAfterDays={archiveAfterDays}
                captureFailedMcpCalls={captureFailedMcpCalls}
                soloSessionDeleteAfterDays={soloSessionDeleteAfterDays}
                openDashboardOnBoot={openDashboardOnBoot}
                showWelcomeToast={showWelcomeToast}
                hideEmptyWorkstreams={hideEmptyWorkstreams}
                hiddenWorkstreamCount={hiddenWorkstreamCount}
                showWorkstreamContextBar={showWorkstreamContextBar}
                onArchiveAfterDaysChange={onUpdateArchiveAfterDays}
                onCaptureFailedMcpCallsChange={onCaptureFailedMcpCallsChange}
                onSoloSessionDeleteAfterDaysChange={onUpdateSoloSessionDeleteAfterDays}
                onOpenDashboardOnBootChange={onOpenDashboardOnBootChange}
                onShowWelcomeToastChange={onShowWelcomeToastChange}
                onHideEmptyWorkstreamsChange={onHideEmptyWorkstreamsChange}
                onShowWorkstreamContextBarChange={onShowWorkstreamContextBarChange}
              />
              <ArchivedRequestsDialog
                loading={archivedRequestsLoading}
                requests={archivedRequests}
                onOpen={onOpenArchivedRequests}
                onRestoreWorkRequest={onRestoreWorkRequest}
                refreshVersion={surfaceRefreshVersion}
              />
              <Button variant="outline" size="sm" onClick={() => void onRefreshDashboard()} disabled={refreshing} className="button-lift">
                {refreshing ? <Loader2 className="size-4 animate-spin" /> : <RefreshCw className="size-4" />}
                Refresh
              </Button>
              <NewRequestDialog
                canCopyArchitectHandoff={architectHandoffEligibleRequest}
                onCopyArchitectHandoff={copyArchitectHandoff}
                onCreateRequest={createWorkRequest}
                open={dialogState.newRequestOpen}
                onOpenChange={onSetNewRequestOpen}
                repos={repos}
              />
            </div>
          </div>
          <div className="dashboard-top-panel-shell mx-auto max-w-[1500px] px-4 sm:px-6 lg:px-8">
            <StatusRail
              openPanel={visibleTopPanel}
              attentionItems={attentionItems}
              requestDetails={requestDetails}
              now={dashboardGeneratedAt(dashboard)}
              onJumpToAttention={jumpToAttention}
              onSelectAttention={onSelectAttention}
              updateAnimations={updateAnimations}
            />
          </div>
        </header>

        <div className="mx-auto grid max-w-[1500px] gap-5 px-4 py-5 sm:px-6 lg:px-8">
          {dashboardAlertMessage ? (
            <Card
              className="dashboard-glass-surface motion-card border-rose-200 bg-rose-50 dark:border-rose-700/70 dark:bg-rose-950/45"
            >
              <CardContent
                className="flex flex-wrap items-start justify-between gap-3 p-4 text-sm text-rose-800 dark:text-rose-200"
              >
                <div className="flex items-start gap-3">
                  <AlertCircle className="mt-0.5 size-4 shrink-0" />
                  <div className="grid gap-1">
                    <span className="font-medium">
                      Dashboard error
                    </span>
                    <span>{dashboardAlertMessage}</span>
                  </div>
                </div>
              </CardContent>
            </Card>
          ) : null}

          {loading ? (
            <div className="dashboard-glass-surface grid min-h-[180px] gap-4 rounded-lg border p-5" aria-busy="true" aria-label="Loading workstreams">
              <div className="h-5 w-40 animate-pulse rounded bg-muted" />
              <div className="h-16 animate-pulse rounded bg-muted/70" />
              <div className="h-16 animate-pulse rounded bg-muted/70" />
            </div>
          ) : <Tabs value={workspaceTab} onValueChange={(value) => onWorkspaceTabChange(value as WorkspaceTab)} className="min-w-0 motion-card">
            <div className="dashboard-tabs-row">
              <TabsList className="dashboard-tabs-list">
                <span className="dashboard-tabs-indicator" data-tab={workspaceTab} aria-hidden="true" />
                <TabsTrigger value="workstreams" className="dashboard-tabs-trigger">
                  Repositories
                </TabsTrigger>
                <TabsTrigger value="solo" className="dashboard-tabs-trigger">
                  Solo Sessions
                </TabsTrigger>
              </TabsList>
            </div>
            <WorkspaceTabCarousel activeTab={workspaceTab} paneContent={workspacePanes} />
          </Tabs>}
        </div>

        <DashboardDeferredDialogs
          activeBlockingEdges={dashboardActiveBlockingEdges(dashboard)}
          changeWorkPackageState={changeWorkPackageState}
          changeWorkRequestState={changeWorkRequestState}
          copyArchitectHandoff={copyArchitectHandoff}
          dialogState={dialogState}
          linkedWorkPackageIds={linkedWorkPackageIds}
          requestDetails={requestDetails}
          onJumpToAttention={jumpToAttention}
          onArchiveWorkPackage={onArchiveWorkPackage}
          onArchiveWorkRequest={onArchiveWorkRequest}
          onClearWorkPackageBlocker={onClearWorkPackageBlocker}
          onDeleteWorkRequest={onDeleteWorkRequest}
          onResolveComment={onResolveComment}
          onSelectAttention={onSelectAttention}
          onSelectCard={onSelectCard}
          onSubmitComment={onSubmitComment}
          onSubmitGuidanceAnswer={onSubmitGuidanceAnswer}
        />
        <DashboardWelcomeDialog
          ready={dashboard !== null}
          showWelcomeToast={showWelcomeToast}
          openDashboardOnBoot={openDashboardOnBoot}
          onShowWelcomeToastChange={onShowWelcomeToastChange}
          onOpenDashboardOnBootChange={onOpenDashboardOnBootChange}
        />
      </main>
    </TooltipProvider>
  );
}

type TopPanelCounts = {
  blockers: number;
  guidance: number;
  ready: boolean;
};

export function shouldAutoCloseTopPanel(openPanel: TopPanelKey | null, previous: TopPanelCounts, current: TopPanelCounts) {
  if (!previous.ready || !current.ready) return false;
  return (openPanel === "guidance" && previous.guidance > 0 && current.guidance === 0) || (openPanel === "blockers" && previous.blockers > 0 && current.blockers === 0);
}

function useAutoClosingTopPanel(guidanceCount: number, blockerCount: number, ready: boolean) {
  const currentCounts = { blockers: blockerCount, guidance: guidanceCount, ready };
  const [topPanelState, setTopPanelState] = useState(() => ({
    counts: currentCounts,
    openPanel: readStoredTopPanel(),
  }));
  const visibleTopPanel = shouldAutoCloseTopPanel(topPanelState.openPanel, topPanelState.counts, currentCounts) ? null : topPanelState.openPanel;

  if (visibleTopPanel !== topPanelState.openPanel || !sameTopPanelCounts(topPanelState.counts, currentCounts)) {
    setTopPanelState({ counts: currentCounts, openPanel: visibleTopPanel });
  }

  useEffect(() => {
    writeDashboardUiStateValue("topPanel", visibleTopPanel);
  }, [visibleTopPanel]);

  const setOpenTopPanel = useCallback((openPanel: TopPanelKey | null) => {
    setTopPanelState((state) => (state.openPanel === openPanel ? state : { ...state, openPanel }));
  }, []);

  return [visibleTopPanel, setOpenTopPanel] as const;
}

function sameTopPanelCounts(left: TopPanelCounts, right: TopPanelCounts) {
  return left.blockers === right.blockers && left.guidance === right.guidance && left.ready === right.ready;
}

function dashboardGeneratedAt(dashboard: DashboardPayload | null) {
  return dashboard?.generated_at;
}

function dashboardActiveBlockingEdges(dashboard: DashboardPayload | null) {
  return dashboard?.active_blocking_edges ?? [];
}

function useDashboardScrollbarOffset(headerRef: React.RefObject<HTMLElement | null>, loading: boolean) {
  useLayoutEffect(() => {
    const update = () => {
      document.documentElement.style.setProperty("--dashboard-scrollbar-top-offset", `${Math.ceil(headerRef.current?.getBoundingClientRect().height ?? 0)}px`);
    };

    update();

    const header = headerRef.current;
    const observer = header && typeof ResizeObserver !== "undefined" ? new ResizeObserver(update) : null;
    if (header && observer) observer.observe(header);
    window.addEventListener("resize", update);

    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", update);
      document.documentElement.style.removeProperty("--dashboard-scrollbar-top-offset");
    };
  }, [headerRef, loading]);
}
