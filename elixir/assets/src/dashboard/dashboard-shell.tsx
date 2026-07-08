import { AlertCircle, Loader2, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import type { CopyArchitectHandoff, DashboardPayload, GuidanceAnswerSubmission, GuidanceItem, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import { GuidanceDialog } from "@/components/dashboard/guidance-dialog";
import { NewRequestDialog } from "@/components/dashboard/new-request-dialog";
import type { NewRequestForm } from "@/components/dashboard/new-request-dialog";
import type * as React from "react";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { TooltipProvider } from "@/components/ui/tooltip";
import { architectHandoffEligibleRequest } from "@/lib/operational-state";
import { cn } from "@/lib/utils";
import { AppDialogState, BlockerItem } from "./dashboard-state";
import { ArchivedRequestsDialog, DashboardSettingsDialog, ThemeToggle } from "./dashboard-settings";
import { CardDetailDialog } from "./card-detail-dialog";
import { CardDetailSelection, DASHBOARD_LOGO_URL, DashboardConnectionIssue, DashboardTheme, DashboardUpdateAnimations, LOCAL_OPERATOR_AUTH_REQUIRED_MESSAGE, ResolveContextComment, SubmitContextComment, TopPanelKey, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, WorkspaceTab, isLocalOperatorAuthRequiredMessage } from "./runtime";
import { LiveLedgerBadge } from "./status-cards";
import { RepoSummary } from "./dashboard-data";
import { DashboardSearchControl } from "./dashboard-search-control";
import { DashboardWelcomeDialog } from "./dashboard-welcome";
import { AttentionBarControls } from "./attention-bar-controls";
import { StatusRail } from "./status-rail";
import { UpdateSimulationControls } from "./update-simulation-controls";
import { WorkspaceTabCarousel } from "./workspace-tabs";
import { readStoredTopPanel, writeDashboardUiStateValue } from "./dashboard-persistence";

type DashboardDisplayPreferences = {
  hideEmptyWorkstreams: boolean;
  showWorkstreamContextBar: boolean;
};

export function DashboardShell({
  archiveAfterDays,
  archivedRequests,
  blockerItems,
  canMutateComments,
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
  guidanceItems,
  hiddenWorkstreamCount,
  linkedWorkPackageIds,
  loading,
  canMutateOperatorActions,
  onArchiveWorkPackage,
  onArchiveWorkRequest,
  onClearWorkPackageBlocker,
  onDeleteWorkRequest,
  onDashboardSearchQueryChange,
  onHideEmptyWorkstreamsChange,
  onOpenDashboardOnBootChange,
  onReconnectDashboard,
  onRefreshDashboard,
  onResolveComment,
  onRestoreWorkRequest,
  onSelectCard,
  onSelectGuidance,
  onSetNewRequestOpen,
  onShowWorkstreamContextBarChange,
  onShowWelcomeToastChange,
  onSubmitComment,
  onSubmitGuidanceAnswer,
  onUpdateArchiveAfterDays,
  onUpdateSoloSessionDeleteAfterDays,
  onWorkspaceTabChange,
  refreshing,
  repos,
  showUpdateSimulationControls,
  openDashboardOnBoot,
  showWelcomeToast,
  soloSessionDeleteAfterDays,
  theme,
  toggleTheme,
  updateAnimations,
  workspacePanes,
  workspaceTab,
}: {
  archiveAfterDays: number;
  archivedRequests: WorkRequestCard[];
  blockerItems: BlockerItem[];
  canMutateComments: boolean;
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
  guidanceItems: GuidanceItem[];
  hiddenWorkstreamCount: number;
  linkedWorkPackageIds: Set<string>;
  loading: boolean;
  canMutateOperatorActions: boolean;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  onArchiveWorkRequest: WorkRequestMutation;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  onDeleteWorkRequest: WorkRequestMutation;
  onDashboardSearchQueryChange: (query: string) => void;
  onHideEmptyWorkstreamsChange: (hide: boolean) => void;
  onOpenDashboardOnBootChange: (open: boolean) => Promise<void>;
  onReconnectDashboard: () => Promise<void>;
  onRefreshDashboard: () => Promise<void>;
  onResolveComment: ResolveContextComment;
  onRestoreWorkRequest: WorkRequestMutation;
  onSelectCard: (selection: CardDetailSelection | null) => void;
  onSelectGuidance: (item: GuidanceItem | null) => void;
  onSetNewRequestOpen: (open: boolean) => void;
  onShowWorkstreamContextBarChange: (show: boolean) => void;
  onShowWelcomeToastChange: (show: boolean) => void;
  onSubmitComment: SubmitContextComment;
  onSubmitGuidanceAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
  onUpdateArchiveAfterDays: (archiveAfterDays: number) => Promise<void>;
  onUpdateSoloSessionDeleteAfterDays: (deleteAfterDays: number) => Promise<void>;
  onWorkspaceTabChange: (tab: WorkspaceTab) => void;
  refreshing: boolean;
  repos: RepoSummary[];
  showUpdateSimulationControls: boolean;
  openDashboardOnBoot: boolean;
  showWelcomeToast: boolean;
  soloSessionDeleteAfterDays: number;
  theme: DashboardTheme;
  toggleTheme: () => void;
  updateAnimations: DashboardUpdateAnimations;
  workspacePanes: Record<WorkspaceTab, React.ReactNode>;
  workspaceTab: WorkspaceTab;
}) {
  const { hideEmptyWorkstreams, showWorkstreamContextBar } = displayPreferences;
  const localOperatorReconnectIssue = isLocalOperatorAuthRequiredMessage(error) || connectionIssue?.reconnectableLocalSession === true;
  const dashboardAlertMessage = error || (localOperatorReconnectIssue ? connectionIssue?.message || LOCAL_OPERATOR_AUTH_REQUIRED_MESSAGE : null);
  const [visibleTopPanel, setOpenTopPanel] = useAutoClosingTopPanel(guidanceItems.length, blockerItems.length, dashboard !== null);
  const headerRef = useRef<HTMLElement | null>(null);

  useDashboardScrollbarOffset(headerRef, loading);

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center">
        <div className="flex items-center gap-3 rounded-lg border bg-card px-5 py-4 text-sm text-muted-foreground shadow-sm">
          <Loader2 className="size-4 animate-spin" />
          Loading Symphony++
        </div>
      </main>
    );
  }

  return (
    <TooltipProvider delayDuration={150}>
      <main className="dashboard-shell min-h-screen">
        <header ref={headerRef} className="dashboard-header-glass sticky top-0 z-20">
          <div className="mx-auto flex max-w-[1500px] flex-col gap-4 px-4 py-4 sm:px-6 lg:flex-row lg:items-center lg:justify-between lg:px-8">
            <div className="flex items-center gap-3">
              <div className="flex size-10 items-center justify-center overflow-hidden rounded-lg border bg-card shadow-sm motion-pop">
                <img src={DASHBOARD_LOGO_URL} alt="Symphony++" className="h-full w-full scale-[1.34] object-contain" />
              </div>
              <div>
                <h1 className="text-xl font-semibold">Symphony++</h1>
                <p className="text-sm text-muted-foreground">Operator cockpit</p>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              {showUpdateSimulationControls ? <UpdateSimulationControls updateAnimations={updateAnimations} /> : null}
              <LiveLedgerBadge error={error} connectionIssue={connectionIssue} databasePath={dashboard?.ledger?.database} />
              <DashboardSearchControl value={dashboardSearchQuery} onValueChange={onDashboardSearchQueryChange} />
              <AttentionBarControls
                guidanceItems={guidanceItems}
                blockerItems={blockerItems}
                openPanel={visibleTopPanel}
                onToggle={setOpenTopPanel}
                updateAnimations={updateAnimations}
              />
              <ThemeToggle theme={theme} onToggle={toggleTheme} />
              <DashboardSettingsDialog
                archiveAfterDays={archiveAfterDays}
                canUpdateRetentionSettings={canMutateOperatorActions}
                soloSessionDeleteAfterDays={soloSessionDeleteAfterDays}
                openDashboardOnBoot={openDashboardOnBoot}
                showWelcomeToast={showWelcomeToast}
                hideEmptyWorkstreams={hideEmptyWorkstreams}
                hiddenWorkstreamCount={hiddenWorkstreamCount}
                showWorkstreamContextBar={showWorkstreamContextBar}
                onArchiveAfterDaysChange={onUpdateArchiveAfterDays}
                onSoloSessionDeleteAfterDaysChange={onUpdateSoloSessionDeleteAfterDays}
                onOpenDashboardOnBootChange={onOpenDashboardOnBootChange}
                onShowWelcomeToastChange={onShowWelcomeToastChange}
                onHideEmptyWorkstreamsChange={onHideEmptyWorkstreamsChange}
                onShowWorkstreamContextBarChange={onShowWorkstreamContextBarChange}
              />
              <ArchivedRequestsDialog canRestoreWorkRequest={canMutateOperatorActions} requests={archivedRequests} onRestoreWorkRequest={onRestoreWorkRequest} />
              <Button variant="outline" size="sm" onClick={() => void onRefreshDashboard()} disabled={refreshing} className="button-lift">
                {refreshing ? <Loader2 className="size-4 animate-spin" /> : <RefreshCw className="size-4" />}
                Refresh
              </Button>
              {canMutateOperatorActions ? (
                <NewRequestDialog
                  canCopyArchitectHandoff={architectHandoffEligibleRequest}
                  onCopyArchitectHandoff={copyArchitectHandoff}
                  onCreateRequest={createWorkRequest}
                  open={dialogState.newRequestOpen}
                  onOpenChange={onSetNewRequestOpen}
                  repos={repos}
                />
              ) : null}
            </div>
          </div>
          <div className="dashboard-top-panel-shell mx-auto max-w-[1500px] px-4 sm:px-6 lg:px-8">
            <StatusRail
              openPanel={visibleTopPanel}
              guidanceItems={guidanceItems}
              blockerItems={blockerItems}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              updateAnimations={updateAnimations}
            />
          </div>
        </header>

        <div className="mx-auto grid max-w-[1500px] gap-5 px-4 py-5 sm:px-6 lg:px-8">
          {dashboardAlertMessage ? (
            <Card
              className={cn(
                "dashboard-glass-surface motion-card",
                localOperatorReconnectIssue
                  ? "border-amber-200 bg-amber-50 dark:border-amber-700/70 dark:bg-amber-950/45"
                  : "border-rose-200 bg-rose-50 dark:border-rose-700/70 dark:bg-rose-950/45",
              )}
            >
              <CardContent
                className={cn(
                  "flex flex-wrap items-start justify-between gap-3 p-4 text-sm",
                  localOperatorReconnectIssue ? "text-amber-900 dark:text-amber-100" : "text-rose-800 dark:text-rose-200",
                )}
              >
                <div className="flex items-start gap-3">
                  <AlertCircle className="mt-0.5 size-4 shrink-0" />
                  <div className="grid gap-1">
                    <span className="font-medium">
                      {localOperatorReconnectIssue ? "Local operator reconnect" : "Dashboard error"}
                    </span>
                    <span>{dashboardAlertMessage}</span>
                  </div>
                </div>
                {localOperatorReconnectIssue ? (
                  <Button variant="outline" size="sm" onClick={() => void onReconnectDashboard()} disabled={refreshing} className="button-lift">
                    {refreshing ? <Loader2 className="size-4 animate-spin" /> : <RefreshCw className="size-4" />}
                    Reconnect
                  </Button>
                ) : null}
              </CardContent>
            </Card>
          ) : null}

          <Tabs value={workspaceTab} onValueChange={(value) => onWorkspaceTabChange(value as WorkspaceTab)} className="min-w-0 motion-card">
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
          </Tabs>
        </div>

        <GuidanceDialog
          canSubmitAnswer={canMutateOperatorActions}
          item={dialogState.selectedGuidance}
          onOpenChange={(open) => {
            if (!open) onSelectGuidance(null);
          }}
          onSubmitAnswer={onSubmitGuidanceAnswer}
        />
        <CardDetailDialog
          selection={dialogState.selectedCardDetail}
          onOpenChange={(open) => {
            if (!open) onSelectCard(null);
          }}
          onSelectGuidance={onSelectGuidance}
          onCopyArchitectHandoff={copyArchitectHandoff}
          onArchiveWorkRequest={onArchiveWorkRequest}
          onChangeWorkRequestState={changeWorkRequestState}
          onDeleteWorkRequest={onDeleteWorkRequest}
          onChangeWorkPackageState={changeWorkPackageState}
          onArchiveWorkPackage={onArchiveWorkPackage}
          onClearWorkPackageBlocker={onClearWorkPackageBlocker}
          canMutateOperatorActions={canMutateOperatorActions}
          linkedWorkPackageIds={linkedWorkPackageIds}
          onSubmitComment={onSubmitComment}
          onResolveComment={onResolveComment}
          canMutateComments={canMutateComments}
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
